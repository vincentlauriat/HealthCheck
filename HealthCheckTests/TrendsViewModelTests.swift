import XCTest
@testable import HealthCheck

final class TrendsViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(60), creationDate: start)
    }

    private func sleepRecord(sourceName: String, value: String, start: Date, end: Date) -> SleepRecord {
        SleepRecord(type: "HKCategoryTypeIdentifierSleepAnalysis", sourceName: sourceName, device: nil, value: value, startDate: start, endDate: end, creationDate: start)
    }

    @MainActor
    func test_load_averagesRestingHeartRatePerDayAfterSourceResolution() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Date()
        let day1 = Calendar.current.startOfDay(for: now).addingTimeInterval(3600)

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "iPhone", value: 60, start: day1),
            record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch", value: 58, start: day1)
        ])

        let viewModel = TrendsViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .all)

        XCTAssertEqual(viewModel.restingHeartRate.count, 1)
        XCTAssertEqual(viewModel.restingHeartRate.first?.value, 58, "Watch wins the source-priority overlap, so only its value is averaged")
    }

    @MainActor
    func test_load_sumsSleepDurationPerNightAcrossMidnight() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        // A session from 23:00 the previous day to 01:00 today must count as ONE night.
        let sessionStart = startOfToday.addingTimeInterval(-3600)
        let sessionEnd = startOfToday.addingTimeInterval(3600)

        try store.insertSleepRecords([
            sleepRecord(sourceName: "Watch", value: "HKCategoryValueSleepAnalysisAsleepCore", start: sessionStart, end: sessionEnd),
            sleepRecord(sourceName: "Watch", value: "HKCategoryValueSleepAnalysisAwake", start: sessionEnd, end: sessionEnd.addingTimeInterval(300))
        ])

        let viewModel = TrendsViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .all)

        XCTAssertEqual(viewModel.sleepHours.count, 1, "both segments belong to the same pre-midnight-shifted night bucket")
        XCTAssertEqual(viewModel.sleepHours.first?.value, 2.0, "only the 2-hour Asleep segment counts, not the Awake one")
    }
}
