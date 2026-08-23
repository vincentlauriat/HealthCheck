import Foundation
import Security

/// Jeton Bearer du Mac appairé, dans le trousseau (spec §8 : Keychain côté
/// iOS, fichier chmod 600 côté Mac).
final class KeychainTokenStore {
    private let service: String

    init(service: String = "fr.vincentlauriat.healthcheck.companion") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "mac-token"]
    }

    func currentToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(token: String) throws {
        clear()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        // Accessible dès le premier déverrouillage post-redémarrage (pas
        // seulement appareil déverrouillé) : un réveil HealthKit en
        // arrière-plan avant le premier déverrouillage doit pouvoir lire le
        // jeton pour synchroniser.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
