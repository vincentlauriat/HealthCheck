import Foundation
import CryptoKit

struct SleepRecord: Equatable, TimedHealthValue {
    let type: String
    let sourceName: String
    let device: String?
    let value: String
    let startDate: Date
    let endDate: Date
    let creationDate: Date?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var dedupKey: String {
        let raw = [
            type,
            sourceName,
            device ?? "",
            value,
            Self.isoFormatter.string(from: startDate),
            Self.isoFormatter.string(from: endDate)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
