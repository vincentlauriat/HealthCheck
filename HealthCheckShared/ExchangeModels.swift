import Foundation

/// Format d'échange iPhone → Mac. Compilé dans les deux apps (groupe
/// source partagé, pas de framework) : une seule définition, aucune
/// dérive possible entre les deux côtés.
enum CompanionProtocol {
    static let serviceType = "_healthcheck._tcp"
    static let batchLimit = 500
    static let pairPath = "/pair"
    static let batchPath = "/batch"
    static let statusPath = "/status"
}

struct ExchangeRecord: Codable, Equatable {
    let type: String
    let sourceName: String
    let device: String?
    let unit: String?
    let value: Double
    let startDate: Date
    let endDate: Date
    let creationDate: Date?
}

struct ExchangeSleep: Codable, Equatable {
    let type: String
    let sourceName: String
    let device: String?
    let value: String
    let startDate: Date
    let endDate: Date
    let creationDate: Date?
}

struct ExchangeRoutePoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
}

struct ExchangeWorkout: Codable, Equatable {
    let activityType: String
    let sourceName: String
    let duration: Double
    let durationUnit: String
    let totalDistance: Double?
    let totalDistanceUnit: String?
    let totalEnergyBurned: Double?
    let totalEnergyBurnedUnit: String?
    let startDate: Date
    let endDate: Date
    let routePoints: [ExchangeRoutePoint]?
}

struct ExchangeBatch: Codable, Equatable {
    let records: [ExchangeRecord]
    let sleep: [ExchangeSleep]
    let workouts: [ExchangeWorkout]
}

struct PairRequest: Codable, Equatable {
    let code: String
}

struct PairResponse: Codable, Equatable {
    let token: String
}

struct BatchResponse: Codable, Equatable {
    let inserted: Int
}

struct StatusResponse: Codable, Equatable {
    let app: String
    let version: String
}

/// Coders JSON partagés : dates ISO8601 avec fractions de seconde,
/// même format que `HealthRecord.isoFormatter`.
enum ExchangeCoding {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = isoFormatter.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "date invalide: \(s)"))
            }
            return date
        }
        return d
    }()
}
