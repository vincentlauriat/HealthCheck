import XCTest
@testable import HealthCheck

@MainActor
final class BodyViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    private func record(_ type: String, value: Double, date: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: "Withings", device: nil, unit: "kg", value: value, startDate: date, endDate: date, creationDate: date)
    }

    func test_load_anchorsDeltasOnLastWeighInNotOnToday() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        // Dernière pesée il y a 60 jours ; référence 30 j avant elle.
        let lastWeighIn = calendar.date(byAdding: .day, value: -60, to: now)!
        let reference = calendar.date(byAdding: .day, value: -32, to: lastWeighIn)!
        try store.insertRecords([
            record("HKQuantityTypeIdentifierBodyMass", value: 91.0, date: reference),
            record("HKQuantityTypeIdentifierBodyMass", value: 89.5, date: lastWeighIn)
        ])

        let viewModel = BodyViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar,
            now: { now }
        )
        try viewModel.load(period: .all)

        XCTAssertEqual(viewModel.latest?.weight, 89.5)
        XCTAssertEqual(viewModel.weightDelta30d!, -1.5, accuracy: 0.001,
                       "le delta 30 j compare la dernière pesée à la pesée d'il y a ≥30 j, même si la balance ne sert plus")
        XCTAssertNil(viewModel.weightDelta1y, "aucune pesée un an avant la dernière")
    }

    func test_load_filtersChartToPeriodButKeepsGlobalLatest() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = calendar.date(byAdding: .month, value: -8, to: now)!
        let recent = calendar.date(byAdding: .day, value: -10, to: now)!
        try store.insertRecords([
            record("HKQuantityTypeIdentifierBodyMass", value: 92.0, date: old),
            record("HKQuantityTypeIdentifierBodyMass", value: 89.0, date: recent)
        ])

        let viewModel = BodyViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar,
            now: { now }
        )
        try viewModel.load(period: .threeMonths)

        XCTAssertEqual(viewModel.snapshots.count, 1, "le graphique ne montre que la période choisie")
        XCTAssertEqual(viewModel.latest?.weight, 89.0)
    }

    // Poids : moyenne antérieure (14 jours avant la fenêtre récente) 100 kg,
    // moyenne récente (14 derniers jours) 97 kg -> rythme -1.5 kg/semaine ->
    // 1,5 % du poids corporel/semaine (recentAverage = 97), au-dessus de
    // safeWarningRatePercent (1.0).
    private func insertWeightHistory(_ store: HealthStore, now: Date, calendar: Calendar) throws {
        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 100,
                  start: calendar.date(byAdding: .day, value: -20, to: now)!),
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 97,
                  start: calendar.date(byAdding: .day, value: -5, to: now)!)
        ])
    }

    func test_load_weightTrend_computesRateFromFullHistory() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertEqual(viewModel.weightTrend?.weeklyRateKg ?? .nan, -1.5, accuracy: 0.001)
        XCTAssertEqual(viewModel.weightTrend?.direction, .losing)
    }

    func test_load_weightSafetyAlert_alwaysUsesUnelevatedTrainingLoad() throws {
        // BodyViewModel n'a pas de LoadAssessment — trainingLoadElevated
        // doit toujours être false ici, donc le message ne doit jamais
        // mentionner la charge d'entraînement, même à un rythme qui le
        // justifierait sur Accueil.
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertEqual(viewModel.weightSafetyAlert?.severity, .warning)
        XCTAssertFalse(viewModel.weightSafetyAlert?.message.contains("charge d'entraînement") ?? true)
    }

    func test_load_weightTrajectory_nilWithoutActiveGoal() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertNil(viewModel.weightGoal)
        XCTAssertNil(viewModel.weightTrajectory)
    }

    func test_load_weightTrajectory_computedWhenActiveGoalExists() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)
        // target 90 from recentAverage 97 (see insertWeightHistory above),
        // 10 weeks (70 days) remaining -> required (90-97)/10 = -0.7 kg/week ;
        // actual -1.5 -> ratio (-1.5)/(-0.7) ≈ 2.14, clearly > 1.2 -> .tooFast.
        try store.saveWeightGoal(WeightGoal(id: "g", targetWeightKg: 90,
                                            targetDate: calendar.date(byAdding: .day, value: 70, to: now)!,
                                            createdAt: now))

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertEqual(viewModel.weightGoal?.targetWeightKg, 90)
        XCTAssertEqual(viewModel.weightTrajectory?.verdict, .tooFast)
    }

    func test_createWeightGoal_thenDeleteActiveWeightGoal_roundTripsThroughLoad() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: 90, to: now)!

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.createWeightGoal(targetWeightKg: 68, targetDate: target)
        try viewModel.load(period: .oneYear)
        XCTAssertEqual(viewModel.weightGoal?.targetWeightKg, 68)

        try viewModel.deleteActiveWeightGoal()
        try viewModel.load(period: .oneYear)
        XCTAssertNil(viewModel.weightGoal)
    }
}
