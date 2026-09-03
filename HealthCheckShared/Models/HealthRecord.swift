import Foundation

struct HealthRecord: Equatable, TimedHealthValue {
    let type: String
    let sourceName: String
    let device: String?
    let unit: String?
    let value: Double
    let startDate: Date
    let endDate: Date
    let creationDate: Date?


    var dedupKey: String {
        DedupKey.digest([
            type,
            sourceName,
            unit ?? "",
            DedupKey.rounded(value),
            DedupKey.second(startDate),
            DedupKey.second(endDate)
        ])
    }
}
