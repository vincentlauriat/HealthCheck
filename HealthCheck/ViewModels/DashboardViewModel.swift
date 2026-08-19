import Foundation

struct PeriodSummary {
    let steps: Double
    let distanceKm: Double
    let activeEnergyKcal: Double
    let exerciseMinutes: Double
    let restingHeartRate: Double?
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var today: PeriodSummary?
    @Published private(set) var thisWeek: PeriodSummary?
    @Published private(set) var loadError: Error?

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, resolver: SourcePriorityResolver, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
    }

    func loadToday() throws {
        let startOfDay = calendar.startOfDay(for: now())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        today = try summary(from: startOfDay, to: endOfDay)
    }

    func loadThisWeek() throws {
        let interval = calendar.dateInterval(of: .weekOfYear, for: now())!
        thisWeek = try summary(from: interval.start, to: interval.end)
    }

    private func summary(from: Date, to: Date) throws -> PeriodSummary {
        let steps = try sum(type: "HKQuantityTypeIdentifierStepCount", from: from, to: to)
        let distance = try sum(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", from: from, to: to)
        let energy = try sum(type: "HKQuantityTypeIdentifierActiveEnergyBurned", from: from, to: to)
        let exercise = try sum(type: "HKQuantityTypeIdentifierAppleExerciseTime", from: from, to: to)
        let restingHR = try resolver
            .resolve(store.records(type: "HKQuantityTypeIdentifierRestingHeartRate", from: from, to: to))
            .sorted(by: { $0.startDate > $1.startDate })
            .first?.value

        return PeriodSummary(steps: steps, distanceKm: distance, activeEnergyKcal: energy, exerciseMinutes: exercise, restingHeartRate: restingHR)
    }

    private func sum(type: String, from: Date, to: Date) throws -> Double {
        resolver.resolve(try store.records(type: type, from: from, to: to)).reduce(0) { $0 + $1.value }
    }
}
