import XCTest
@testable import HealthCheckCompanion

/// Premiers tests d'`ActivityViewModel` : il n'en avait aucun, ni côté macOS
/// ni ailleurs. Les fixtures posent leurs mesures avant `now`, parce que
/// `HealthStore.records` borne à `startDate < to`.
@MainActor
final class ActivityViewModelTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    /// Horloge fixe à 20 h locale : laisse la place pour poser des mesures
    /// dans la journée, et évite les échecs à minuit.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func heartRate(_ value: Double, at date: Date) -> HealthRecord {
        HealthRecord(type: "HKQuantityTypeIdentifierHeartRate", sourceName: "Watch",
                     device: nil, unit: "count/min", value: value,
                     startDate: date, endDate: date, creationDate: date)
    }

    func test_load_usesTheObservedMaximumHeartRate_clampedToAPlausibleRange() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        // Un pic à 180 il y a 100 jours : dans la fenêtre de 2 ans du view model.
        try store.insertRecords([heartRate(180, at: calendar.date(byAdding: .day, value: -100, to: now)!)])

        let viewModel = ActivityViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertEqual(viewModel.maxHeartRate, 180,
                       "la FC max observée sur 2 ans sert de référence aux zones")
    }

    func test_load_withNoHeartRateAtAll_leavesEverythingEmptyWithoutThrowing() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = ActivityViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.maxHeartRate)
        XCTAssertNil(viewModel.today)
        XCTAssertTrue(viewModel.history.isEmpty)
    }

    func test_load_buildsTodayStrainAndTodaysEnergyAndExercise() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let startOfToday = calendar.startOfDay(for: now)

        var records = [heartRate(180, at: calendar.date(byAdding: .day, value: -100, to: now)!)]
        // Une heure d'effort ce matin : 13 points à 150 bpm espacés de 5 min.
        for step in 0..<13 {
            records.append(heartRate(150, at: startOfToday.addingTimeInterval(8 * 3600 + Double(step) * 300)))
        }
        records.append(HealthRecord(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                                    sourceName: "Watch", device: nil, unit: "kcal", value: 420,
                                    startDate: startOfToday.addingTimeInterval(9 * 3600),
                                    endDate: startOfToday.addingTimeInterval(9 * 3600 + 60),
                                    creationDate: nil))
        records.append(HealthRecord(type: "HKQuantityTypeIdentifierAppleExerciseTime",
                                    sourceName: "Watch", device: nil, unit: "min", value: 55,
                                    startDate: startOfToday.addingTimeInterval(9 * 3600),
                                    endDate: startOfToday.addingTimeInterval(9 * 3600 + 60),
                                    creationDate: nil))
        try store.insertRecords(records)

        let viewModel = ActivityViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        let today = try XCTUnwrap(viewModel.today)
        XCTAssertEqual(today.day, startOfToday)
        XCTAssertGreaterThan(today.score, 0, "une heure à 150 bpm doit produire un effort non nul")
        XCTAssertGreaterThan(today.zoneMinutes.reduce(0, +), 0)
        XCTAssertEqual(viewModel.todayActiveEnergy, 420)
        XCTAssertEqual(viewModel.todayExerciseMinutes, 55)
    }
}
