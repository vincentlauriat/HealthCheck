import XCTest
@testable import HealthCheckCompanion

@MainActor
final class CompanionAdvisorViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    // Baseline dégradée : FC repos +10 % vs. 10 jours à 60 bpm -> readiness
    // "Récupération conseillée" -> palier .repos. Fixture identique à celle
    // du sous-projet 3 (weight-advisor), déjà vérifiée produire ce résultat.
    private func insertDegradedRestingHRHistory(_ store: HealthStore, now: Date, calendar: Calendar) throws {
        var records: [HealthRecord] = (1...10).map { daysAgo in
            record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch", value: 60,
                  start: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600))
        }
        records.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch",
                              value: 66, start: calendar.startOfDay(for: now).addingTimeInterval(3600)))
        try store.insertRecords(records)
    }

    func test_refresh_computesReadinessAndDailyAdviceFromLocalStore() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertDegradedRestingHRHistory(store, now: now, calendar: calendar)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertEqual(viewModel.readiness?.label, "Récupération conseillée")
        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_refresh_vo2MaxTrendComputedFromLocalStore() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        // Fenêtre récente (30j) à 45, fenêtre antérieure (30-120j) à 40 ->
        // delta +5, largement au-dessus de meaningfulDeltaThreshold (1.0) -> .rising.
        var records: [HealthRecord] = []
        for daysAgo in stride(from: 5, through: 25, by: 10) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 45,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        for daysAgo in stride(from: 45, through: 105, by: 20) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        try store.insertRecords(records)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        viewModel.refresh()

        XCTAssertEqual(viewModel.vo2Trend?.verdict, .rising)
    }

    func test_refresh_emptyStore_readinessAndAdviceAreNilWithoutError() throws {
        let store = try HealthStore(path: ":memory:")
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertNil(viewModel.readiness)
        XCTAssertNil(viewModel.dailyAdvice)
        XCTAssertNil(viewModel.vo2Trend)
    }

    func test_refresh_storeUnavailable_setsFlagWithoutThrowing() {
        let store = HealthStore(unavailable: ())
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.storeUnavailable)
        XCTAssertNil(viewModel.readiness)
        XCTAssertNil(viewModel.dailyAdvice)
    }

    // Non-goal de la spec §2 : même si des données de poids existent en
    // base (import antérieur, scénario futur), cet écran ne doit JAMAIS
    // faire remonter d'alerte de poids. Rythme de -1.5 kg/semaine, celui-là
    // même qui déclenche WeightEngine.safetyAlert(.warning) côté sous-projet
    // 3 (weight-advisor) — falsifiable : ce test échouerait si un futur
    // lecteur câblait WeightEngine par erreur sur cet écran.
    func test_refresh_neverSurfacesAWeightAlertEvenIfWeightDataExistsLocally() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertDegradedRestingHRHistory(store, now: now, calendar: calendar)
        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 100,
                  start: calendar.date(byAdding: .day, value: -20, to: now)!),
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 97,
                  start: calendar.date(byAdding: .day, value: -5, to: now)!)
        ])

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        viewModel.refresh()

        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.",
                      "aucune alerte de poids ne doit jamais apparaître sur cet écran (non-goal spec §2), même si des données de poids existent en base")
    }
}
