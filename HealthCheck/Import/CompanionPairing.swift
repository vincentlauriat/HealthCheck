import Foundation

/// Jeton d'appairage du compagnon iPhone, persisté comme les jetons
/// Withings : fichier JSON dans Application Support, chmod 600.
struct CompanionTokenStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HealthCheck", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("companion-token.json") }

    func currentToken() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return payload["token"]
    }

    func save(token: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(["token": token])
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Fenêtre d'appairage : code à 6 chiffres, 120 s, 5 tentatives.
/// Un seul échange réussi par fenêtre ; le jeton émis est persistant.
final class PairingManager {
    static let windowDuration: TimeInterval = 120
    static let maxAttempts = 5

    private let tokenStore: CompanionTokenStore
    private let now: () -> Date
    private let codeGenerator: () -> String

    private var code: String?
    private var opensAt: Date?
    private var attempts = 0

    init(tokenStore: CompanionTokenStore,
         now: @escaping () -> Date = Date.init,
         codeGenerator: @escaping () -> String = PairingManager.randomCode) {
        self.tokenStore = tokenStore
        self.now = now
        self.codeGenerator = codeGenerator
    }

    var isWindowOpen: Bool {
        guard let opensAt, code != nil else { return false }
        return now().timeIntervalSince(opensAt) < Self.windowDuration && attempts < Self.maxAttempts
    }

    func openWindow() -> String {
        let newCode = codeGenerator()
        code = newCode
        opensAt = now()
        attempts = 0
        return newCode
    }

    func closeWindow() {
        code = nil
        opensAt = nil
        attempts = 0
    }

    /// `nil` si la fenêtre est fermée, expirée, grillée (5 essais) ou si
    /// le code est faux. Sinon : émet, persiste et retourne le jeton.
    func redeem(code candidate: String) -> String? {
        guard isWindowOpen else { return nil }
        attempts += 1
        guard candidate == code else { return nil }
        let token = Self.randomToken()
        do { try tokenStore.save(token: token) } catch { return nil }
        closeWindow()
        return token
    }

    static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private static func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
