import Foundation
import Network
import AppKit

enum WithingsError: LocalizedError {
    case missingConfig
    case notConnected
    case apiError(Int, String?)
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Configuration Withings absente (withings.json dans Application Support)."
        case .notConnected:
            return "Compte Withings non connecté."
        case .apiError(let status, let message):
            return "Erreur API Withings (statut \(status)\(message.map { " : \($0)" } ?? "..."))"
        case .authFailed(let reason):
            return "Autorisation Withings échouée : \(reason)"
        }
    }
}

/// Client OAuth2 + lecture des mesures. Le flux de connexion ouvre le
/// navigateur sur la page d'autorisation Withings et capte le retour sur un
/// listener localhost éphémère (le callback enregistré dans l'app développeur).
final class WithingsClient {
    private let config: WithingsConfig
    private let session: URLSession

    private static let authorizeURL = "https://account.withings.com/oauth2_user/authorize2"
    private static let tokenURL = URL(string: "https://wbsapi.withings.net/v2/oauth2")!
    private static let measureURL = URL(string: "https://wbsapi.withings.net/measure")!
    private static let callbackPort: UInt16 = 8723

    init?(session: URLSession = .shared) {
        guard let config = WithingsConfig.load() else { return nil }
        self.config = config
        self.session = session
    }

    var isConnected: Bool { WithingsTokens.load() != nil }

    // MARK: - Connexion

    /// Lance le flux d'autorisation complet : listener local, navigateur,
    /// échange du code contre les jetons, persistance.
    func connect() async throws {
        let state = UUID().uuidString
        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "scope", value: "user.metrics"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state)
        ]

        async let callback = waitForCallback()
        _ = await MainActor.run { NSWorkspace.shared.open(components.url!) }
        let (code, returnedState) = try await callback
        guard returnedState == state else { throw WithingsError.authFailed("state inattendu") }

        let body = try await requestToken([
            "action": "requesttoken",
            "grant_type": "authorization_code",
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "code": code,
            "redirect_uri": config.redirectURI
        ])
        try save(body)
    }

    func disconnect() {
        try? FileManager.default.removeItem(at: WithingsTokens.fileURL)
    }

    // MARK: - Synchronisation

    /// Récupère tout l'historique de composition corporelle (paginé) et le
    /// convertit en enregistrements. L'insertion `INSERT OR IGNORE` du store
    /// rend l'opération idempotente comme l'import de l'export Apple Santé.
    func fetchAllMeasures() async throws -> [HealthRecord] {
        let token = try await validAccessToken()
        var records: [HealthRecord] = []
        var offset: Int? = nil
        repeat {
            var form = [
                "action": "getmeas",
                "meastypes": WithingsMapper.requestedTypes,
                "category": "1"
            ]
            if let offset { form["offset"] = String(offset) }
            let response: WithingsResponse<WithingsMeasureBody> = try await post(
                Self.measureURL, form: form, bearer: token
            )
            guard response.status == 0, let body = response.body else {
                throw WithingsError.apiError(response.status, response.error)
            }
            records.append(contentsOf: WithingsMapper.records(from: body.measuregrps))
            offset = (body.more ?? 0) != 0 ? body.offset : nil
        } while offset != nil
        return records
    }

    // MARK: - Jetons

    private func validAccessToken() async throws -> String {
        guard var tokens = WithingsTokens.load() else { throw WithingsError.notConnected }
        if tokens.expiresAt > Date().addingTimeInterval(60) { return tokens.accessToken }
        let body = try await requestToken([
            "action": "requesttoken",
            "grant_type": "refresh_token",
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": tokens.refreshToken
        ])
        tokens = try save(body)
        return tokens.accessToken
    }

    @discardableResult
    private func save(_ body: WithingsTokenBody) throws -> WithingsTokens {
        let tokens = WithingsTokens(
            accessToken: body.access_token,
            refreshToken: body.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(body.expires_in))
        )
        try tokens.save()
        return tokens
    }

    private func requestToken(_ form: [String: String]) async throws -> WithingsTokenBody {
        let response: WithingsResponse<WithingsTokenBody> = try await post(Self.tokenURL, form: form, bearer: nil)
        guard response.status == 0, let body = response.body else {
            throw WithingsError.apiError(response.status, response.error)
        }
        return body
    }

    private func post<Body: Decodable>(_ url: URL, form: [String: String], bearer: String?) async throws -> WithingsResponse<Body> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(WithingsResponse<Body>.self, from: data)
    }

    // MARK: - Callback localhost

    /// Écoute une unique requête `GET /callback?code=…&state=…` sur le port
    /// enregistré, répond une page de confirmation, puis s'arrête.
    private func waitForCallback() async throws -> (code: String, state: String) {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.callbackPort)!)
        return try await withCheckedThrowingContinuation { continuation in
            let hasResumed = AtomicFlag()

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let result = Self.parseCallback(requestLine: request)
                    let html = result != nil
                        ? "<h2>Withings connecté \u{2705}</h2><p>Vous pouvez fermer cette fen\u{ea}tre et revenir \u{e0} HealthCheck.</p>"
                        : "<h2>Requ\u{ea}te ignor\u{e9}e</h2>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body style=\"font-family:-apple-system;text-align:center;margin-top:80px\">\(html)</body></html>"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        guard let result else { return }
                        listener.cancel()
                        if hasResumed.exchange(true) == false {
                            continuation.resume(returning: result)
                        }
                    })
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state, hasResumed.exchange(true) == false {
                    continuation.resume(throwing: WithingsError.authFailed(error.localizedDescription))
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Extrait `code` et `state` de la première ligne HTTP si c'est bien le
    /// callback attendu (les requêtes parasites type favicon sont ignorées).
    static func parseCallback(requestLine: String) -> (code: String, state: String)? {
        guard let path = requestLine.split(separator: " ").dropFirst().first,
              path.hasPrefix("/callback"),
              let components = URLComponents(string: String(path)),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        else { return nil }
        return (code, state)
    }
}

/// Petit verrou pour garantir une seule reprise de continuation malgré des
/// callbacks réseau concurrents.
private final class AtomicFlag {
    private let lock = NSLock()
    private var value = false

    /// Positionne le drapeau et retourne son ancienne valeur.
    func exchange(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
