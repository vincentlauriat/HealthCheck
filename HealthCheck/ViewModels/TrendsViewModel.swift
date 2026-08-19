import Foundation

struct TrendPoint: Equatable {
    let date: Date
    let value: Double
}

enum TrendPeriod: Hashable {
    case threeMonths
    case sixMonths
    case oneYear
    case all

    func startDate(now: Date, calendar: Calendar) -> Date {
        switch self {
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now) ?? .distantPast
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now) ?? .distantPast
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? .distantPast
        case .all:
            return .distantPast
        }
    }
}

@MainActor
final class TrendsViewModel: ObservableObject {
    @Published private(set) var restingHeartRate: [TrendPoint] = []
    @Published private(set) var weight: [TrendPoint] = []
    @Published private(set) var vo2Max: [TrendPoint] = []
    @Published private(set) var sleepHours: [TrendPoint] = []

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

    func load(period: TrendPeriod) throws {
        let start = period.startDate(now: now(), calendar: calendar)
        let end = now()

        restingHeartRate = try dailyAverage(type: "HKQuantityTypeIdentifierRestingHeartRate", from: start, to: end)
        weight = try dailyAverage(type: "HKQuantityTypeIdentifierBodyMass", from: start, to: end)
        vo2Max = try dailyAverage(type: "HKQuantityTypeIdentifierVO2Max", from: start, to: end)
        sleepHours = try nightlySleepHours(from: start, to: end)
    }

    private func dailyAverage(type: String, from: Date, to: Date) throws -> [TrendPoint] {
        let resolved = resolver.resolve(try store.records(type: type, from: from, to: to))
        let grouped = Dictionary(grouping: resolved) { calendar.startOfDay(for: $0.startDate) }
        return grouped
            .map { day, records in
                TrendPoint(date: day, value: records.reduce(0) { $0 + $1.value } / Double(records.count))
            }
            .sorted { $0.date < $1.date }
    }

    private func nightlySleepHours(from: Date, to: Date) throws -> [TrendPoint] {
        let asleep = try store.sleepRecords(from: from, to: to)
            .filter { $0.value.hasPrefix("HKCategoryValueSleepAnalysisAsleep") }
        let resolved = resolver.resolve(asleep)
        let grouped = Dictionary(grouping: resolved) { record in
            calendar.startOfDay(for: record.startDate.addingTimeInterval(-12 * 3600))
        }
        return grouped
            .map { night, records -> TrendPoint in
                let totalSeconds = records.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                return TrendPoint(date: night, value: totalSeconds / 3600)
            }
            .sorted { $0.date < $1.date }
    }
}
