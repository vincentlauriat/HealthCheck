import Foundation

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


    var dedupKey: String {
        DedupKey.digest([
            activityType,
            sourceName,
            DedupKey.rounded(duration),
            DedupKey.second(startDate),
            DedupKey.second(endDate)
        ])
    }
}
