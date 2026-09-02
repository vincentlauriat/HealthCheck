import XCTest
@testable import HealthCheckCompanion

/// Premiers tests de `SleepViewModel`. Le regroupement par nuit décale de
/// 12 h (`startOfDay(for: start - 12h)`), donc une nuit posée à 23 h est
/// rattachée au jour de son coucher.
@MainActor
final class SleepViewModelTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func segment(_ value: String, from: Date, hours: Double) -> SleepRecord {
        SleepRecord(type: "HKCategoryTypeIdentifierSleepAnalysis", sourceName: "Watch",
                    device: nil, value: value, startDate: from,
                    endDate: from.addingTimeInterval(hours * 3600), creationDate: from)
    }

    /// Une nuit complète : 5 h de sommeil léger, 1,5 h de profond, 1,5 h de REM.
    private func night(startingAt bedtime: Date) -> [SleepRecord] {
        [segment("HKCategoryValueSleepAnalysisAsleepCore", from: bedtime, hours: 5),
         segment("HKCategoryValueSleepAnalysisAsleepDeep", from: bedtime.addingTimeInterval(5 * 3600), hours: 1.5),
         segment("HKCategoryValueSleepAnalysisAsleepREM", from: bedtime.addingTimeInterval(6.5 * 3600), hours: 1.5)]
    }

    func test_load_summarizesTheLastNightAndItsPhases() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let lastBedtime = calendar.startOfDay(for: now).addingTimeInterval(-1 * 3600)  // 23 h hier
        _ = try store.insertSleepRecords(night(startingAt: lastBedtime))

        let viewModel = SleepViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        let last = try XCTUnwrap(viewModel.lastNight)
        XCTAssertEqual(last.asleepHours, 8, accuracy: 0.01)
        XCTAssertEqual(last.deepHours, 1.5, accuracy: 0.01)
        XCTAssertEqual(last.remHours, 1.5, accuracy: 0.01)
        XCTAssertEqual(last.coreHours, 5, accuracy: 0.01)
        XCTAssertGreaterThan(last.score, 0)
    }

    func test_load_averagesAcrossNights() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let lastBedtime = calendar.startOfDay(for: now).addingTimeInterval(-1 * 3600)
        var records = night(startingAt: lastBedtime)
        records += night(startingAt: calendar.date(byAdding: .day, value: -1, to: lastBedtime)!)
        _ = try store.insertSleepRecords(records)

        let viewModel = SleepViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertEqual(viewModel.nights.count, 2)
        XCTAssertEqual(try XCTUnwrap(viewModel.averageHours), 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(viewModel.averageDeepShare), 1.5 / 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(viewModel.averageRemShare), 1.5 / 8, accuracy: 0.01)
    }

    func test_load_withNoSleepAtAll_leavesAveragesNilWithoutThrowing() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = SleepViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.lastNight)
        XCTAssertNil(viewModel.averageHours)
        XCTAssertTrue(viewModel.nights.isEmpty)
    }
}
