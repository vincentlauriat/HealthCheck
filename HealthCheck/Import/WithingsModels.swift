import Foundation

/// Identifiants de l'app développeur Withings de l'utilisateur. Chargés depuis
/// `~/Library/Application Support/HealthCheck/withings.json` — jamais dans le
/// dépôt ni dans le bundle.
struct WithingsConfig: Codable, Equatable {
    let clientId: String
    let clientSecret: String
    let redirectURI: String

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthCheck", isDirectory: true)
            .appendingPathComponent("withings.json")
    }

    static func load() -> WithingsConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WithingsConfig.self, from: data)
    }
}

/// Jetons OAuth2 persistés localement. Le refresh token Withings est à usage
/// unique : chaque rafraîchissement le remplace, d'où la réécriture du fichier
/// après chaque échange.
struct WithingsTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    static var fileURL: URL {
        WithingsConfig.fileURL.deletingLastPathComponent()
            .appendingPathComponent("withings-tokens.json")
    }

    static func load() -> WithingsTokens? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WithingsTokens.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}

// MARK: - Réponses de l'API

/// Enveloppe commune : `status` 0 = succès, tout autre code est une erreur
/// applicative même si le HTTP est 200.
struct WithingsResponse<Body: Decodable>: Decodable {
    let status: Int
    let error: String?
    let body: Body?
}

struct WithingsTokenBody: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}

struct WithingsMeasureBody: Decodable {
    let measuregrps: [WithingsMeasureGroup]
    let more: Int?
    let offset: Int?
}

struct WithingsMeasureGroup: Decodable {
    let date: Int
    let category: Int
    let measures: [WithingsMeasure]
}

struct WithingsMeasure: Decodable {
    let value: Int
    let type: Int
    let unit: Int

    /// Valeur réelle : `value × 10^unit` (l'API encode 89,643 kg en
    /// value=89643, unit=-3).
    var realValue: Double { Double(value) * pow(10, Double(unit)) }
}

// MARK: - Mapping vers HealthRecord

enum WithingsMapper {
    /// Types demandés à `getmeas`. Les trois premiers existent dans HealthKit
    /// (mêmes identifiants que l'export Apple Santé, pour que les écrans
    /// existants les voient) ; les quatre autres n'ont pas d'équivalent
    /// HealthKit et reçoivent un identifiant custom.
    static let requestedTypes = "1,5,6,76,77,88,170"

    // Les valeurs vivent dans `WithingsMeasureType` (partagé) : `BodyViewModel`
    // les lit et tourne sur les deux cibles depuis le SP5. Ces alias gardent
    // les appelants et les tests existants inchangés.
    static let muscleMassType = WithingsMeasureType.muscleMass
    static let hydrationType = WithingsMeasureType.hydration
    static let boneMassType = WithingsMeasureType.boneMass
    static let visceralFatType = WithingsMeasureType.visceralFat

    private static let mapping: [Int: (type: String, unit: String)] = [
        1: ("HKQuantityTypeIdentifierBodyMass", "kg"),
        5: ("HKQuantityTypeIdentifierLeanBodyMass", "kg"),
        6: ("HKQuantityTypeIdentifierBodyFatPercentage", "%"),
        76: (muscleMassType, "kg"),
        77: (hydrationType, "kg"),
        88: (boneMassType, "kg"),
        170: (visceralFatType, "index")
    ]

    /// Convertit les groupes de mesures en enregistrements insérables. Ne garde
    /// que les vraies mesures (category 1, pas les objectifs), ignore les types
    /// non demandés. Le % de graisse est ramené en fraction (0,253) comme dans
    /// l'export Apple Santé.
    static func records(from groups: [WithingsMeasureGroup]) -> [HealthRecord] {
        groups.filter { $0.category == 1 }.flatMap { group -> [HealthRecord] in
            let date = Date(timeIntervalSince1970: TimeInterval(group.date))
            return group.measures.compactMap { measure in
                guard let target = mapping[measure.type] else { return nil }
                let value = measure.type == 6 ? measure.realValue / 100 : measure.realValue
                return HealthRecord(
                    type: target.type,
                    sourceName: "Withings",
                    device: nil,
                    unit: target.unit,
                    value: value,
                    startDate: date,
                    endDate: date,
                    creationDate: date
                )
            }
        }
    }
}
