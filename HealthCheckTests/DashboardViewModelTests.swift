import XCTest
@testable import HealthCheck

final class DashboardViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    @MainActor
    func test_loadToday_sumsStepsAndDistanceAfterSourceResolution() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let morning = startOfDay.addingTimeInterval(3600)
        let afternoon = startOfDay.addingTimeInterval(3600 * 14)

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "iPhone", value: 100, start: morning),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 90, start: morning),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 200, start: afternoon),
            record(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", sourceName: "Watch", value: 1.5, start: morning),
            record(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", sourceName: "Watch", value: 2.5, start: afternoon)
        ])

        let viewModel = DashboardViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            now: { now }
        )
        try viewModel.loadToday()

        XCTAssertEqual(viewModel.today?.steps, 290, "morning bucket resolves to the Watch value (90), afternoon adds 200")
        XCTAssertEqual(viewModel.today?.distanceKm, 4.0)
    }

    @MainActor
    func test_loadThisWeek_sumsAcrossTheCalendarWeek() throws {
        let store = try HealthStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        let now = Date()
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let earlierThisWeek = startOfWeek.addingTimeInterval(3600)
        let today = calendar.startOfDay(for: now).addingTimeInterval(3600)

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 1000, start: earlierThisWeek),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 500, start: today)
        ])

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), calendar: calendar, now: { now })
        try viewModel.loadThisWeek()

        XCTAssertEqual(viewModel.thisWeek?.steps, 1500)
    }

    @MainActor
    func test_loadThisWeek_alsoLoadsPreviousWeekForComparison() throws {
        let store = try HealthStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        let now = Date()
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let thisWeekSample = startOfWeek.addingTimeInterval(3600)
        let lastWeekSample = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek)!.addingTimeInterval(3600)

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 2000, start: thisWeekSample),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 5000, start: lastWeekSample)
        ])

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), calendar: calendar, now: { now })
        try viewModel.loadThisWeek()

        XCTAssertEqual(viewModel.thisWeek?.steps, 2000)
        XCTAssertEqual(viewModel.lastWeek?.steps, 5000, "the previous week's sample must land in lastWeek, not thisWeek")
    }
}
