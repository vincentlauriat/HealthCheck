import Foundation
import CryptoKit

struct Workout: Equatable {
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
    let routeFileName: String?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var dedupKey: String {
        let raw = [
            activityType,
            sourceName,
            String(duration),
            Self.isoFormatter.string(from: startDate),
            Self.isoFormatter.string(from: endDate)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
