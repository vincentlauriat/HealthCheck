import Foundation

enum MacClientError: Error, Equatable {
    case unreachable        // Mac introuvable sur le réseau — rien de perdu, on réessaiera
    case unauthorized       // jeton refusé → état « appairage requis »
    case pairingRejected    // fenêtre fermée, code faux ou grillé
    case serverError(Int)
    case badResponse
}

/// Fournit l'adresse actuelle du Mac. L'implémentation Bonjour vit dans la
/// couche vive (Task 6) ; les tests injectent un endpoint fixe.
protocol MacEndpointProviding {
    func currentEndpoint() async -> (host: String, port: UInt16)?
}

/// Client HTTP du récepteur Mac. Trois requêtes, sémantique d'erreur alignée
/// sur le tableau §9 de la spec : toute non-2xx laisse l'appelant décider
/// (les ancres n'avancent jamais sur un échec).
final class MacClient {
    private let endpointProvider: MacEndpointProviding
    private let tokenStore: KeychainTokenStore
    private let session: URLSession

    init(endpointProvider: MacEndpointProviding, tokenStore: KeychainTokenStore, session: URLSession = .shared) {
        self.endpointProvider = endpointProvider
        self.tokenStore = tokenStore
        self.session = session
    }

    func pair(code: String) async throws {
        let body = try ExchangeCoding.encoder.encode(PairRequest(code: code))
        let (data, status) = try await send(path: CompanionProtocol.pairPath, method: "POST", body: body, authenticated: false)
        guard status == 200 else { throw status == 401 ? MacClientError.pairingRejected : MacClientError.serverError(status) }
        guard let payload = try? ExchangeCoding.decoder.decode(PairResponse.self, from: data) else {
            throw MacClientError.badResponse
        }
        try tokenStore.save(token: payload.token)
    }

    func push(batch: ExchangeBatch) async throws -> Int {
        let body = try ExchangeCoding.encoder.encode(batch)
        let (data, status) = try await send(path: CompanionProtocol.batchPath, method: "POST", body: body, authenticated: true)
        switch status {
        case 200:
            guard let payload = try? ExchangeCoding.decoder.decode(BatchResponse.self, from: data) else {
                throw MacClientError.badResponse
            }
            return payload.inserted
        case 401: throw MacClientError.unauthorized
        default: throw MacClientError.serverError(status)
        }
    }

    func status() async throws -> StatusResponse {
        let (data, status) = try await send(path: CompanionProtocol.statusPath, method: "GET", body: nil, authenticated: true)
        switch status {
        case 200:
            guard let payload = try? ExchangeCoding.decoder.decode(StatusResponse.self, from: data) else {
                throw MacClientError.badResponse
            }
            return payload
        case 401: throw MacClientError.unauthorized
        default: throw MacClientError.serverError(status)
        }
    }

    private func send(path: String, method: String, body: Data?, authenticated: Bool) async throws -> (Data, Int) {
        guard let endpoint = await endpointProvider.currentEndpoint(),
              let url = URL(string: "http://\(endpoint.host):\(endpoint.port)\(path)")
        else { throw MacClientError.unreachable }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        if authenticated, let token = tokenStore.currentToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            throw MacClientError.unreachable // Mac éteint / réseau différent : cas normal, pas fatal
        }
    }
}

extension MacClient: BatchPushing {}
