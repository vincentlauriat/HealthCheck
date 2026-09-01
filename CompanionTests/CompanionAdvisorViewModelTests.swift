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

    func test_refresh_computesReadinessAndDailyAdviceFromLocalStore() async throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertDegradedRestingHRHistory(store, now: now, calendar: calendar)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertEqual(viewModel.readiness?.label, "Récupération conseillée")
        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_refresh_vo2MaxTrendComputedFromLocalStore() async throws {
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
        await viewModel.refresh()

        XCTAssertEqual(viewModel.vo2Trend?.verdict, .rising)
    }

    func test_refresh_emptyStore_readinessAndAdviceAreNilWithoutError() async throws {
        let store = try HealthStore(path: ":memory:")
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertNil(viewModel.readiness)
        XCTAssertNil(viewModel.dailyAdvice)
        XCTAssertNil(viewModel.vo2Trend)
        XCTAssertNil(viewModel.vo2MaxAlert)
    }

    // Spec §6 item 3 : "verdict de tendance + alerte de stagnation le cas
    // échéant" — la carte VO2max doit pouvoir afficher l'alerte .info
    // (stable sous charge soutenue), pas seulement la .warning qui peut
    // remonter par substitution dans DailyAdviceEngine. Fixture de charge
    // identique (chronic = 10 km/semaine >= meaningfulChronicKm 8.0) à celle
    // déjà vérifiée dans DashboardViewModelTests.
    func test_refresh_exposesVO2MaxStagnationAlertEvenWhenInfoSeverity() async throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current

        // Fenêtre récente (30j) à 40.3, fenêtre antérieure (30-120j) à 40.0 ->
        // delta +0.3, sous meaningfulDeltaThreshold (1.0) -> .stable.
        var records: [HealthRecord] = []
        for daysAgo in stride(from: 5, through: 25, by: 10) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40.3,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        for daysAgo in stride(from: 45, through: 105, by: 20) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40.0,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        try store.insertRecords(records)

        func run(daysAgo: Int, km: Double) -> Workout {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                           duration: 60, durationUnit: "min",
                           totalDistance: km, totalDistanceUnit: "km",
                           totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                           startDate: start, endDate: start.addingTimeInterval(3600),
                           routeFileName: nil)
        }
        try store.insertWorkouts([
            run(daysAgo: 25, km: 10.0),
            run(daysAgo: 18, km: 10.0),
            run(daysAgo: 11, km: 10.0),
            run(daysAgo: 4, km: 10.0)
        ])

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertEqual(viewModel.vo2Trend?.verdict, .stable)
        XCTAssertEqual(viewModel.vo2MaxAlert?.severity, .info)
        XCTAssertEqual(viewModel.vo2MaxAlert?.message,
                      "VO2max stable malgré une charge d'entraînement soutenue — un palier normal, ou un signal pour varier l'intensité.")
    }

    func test_refresh_storeUnavailable_setsFlagWithoutThrowing() async {
        let store = HealthStore(unavailable: ())
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        await viewModel.refresh()

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
    func test_refresh_neverSurfacesAWeightAlertEvenIfWeightDataExistsLocally() async throws {
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
        await viewModel.refresh()

        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.",
                      "aucune alerte de poids ne doit jamais apparaître sur cet écran (non-goal spec §2), même si des données de poids existent en base")
    }
}
