import Foundation

struct SleepRecord: Equatable, TimedHealthValue {
    let type: String
    let sourceName: String
    let device: String?
    let value: String
    let startDate: Date
    let endDate: Date
    let creationDate: Date?


    var dedupKey: String {
        DedupKey.digest([
            type,
            sourceName,
            value,
            DedupKey.second(startDate),
            DedupKey.second(endDate)
        ])
    }
}
