import XCTest
@testable import HealthCheckCompanion

/// Garde du déplacement (SP1) : ces sept view models vivaient dans
/// `HealthCheck/ViewModels/`, compilé par la seule cible macOS. Tant qu'ils ne
/// sont pas dans `HealthCheckShared/ViewModels/`, ce fichier ne compile pas —
/// c'est la forme que prend l'échec attendu, et elle est sans ambiguïté.
///
/// Le store est vide à dessein : ce test ne vérifie pas les calculs (leurs
/// propres tests s'en chargent côté macOS), seulement que les sept view models
/// existent côté iPhone et traversent un `load()` sans lever sur une base
/// neuve — l'état exact d'un Companion fraîchement installé.
@MainActor
final class SharedViewModelsAvailabilityTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    /// Horloge fixe, calée à 20 h locale d'un jour arbitraire : ce dépôt a déjà
    /// connu des échecs à minuit, et une heure tardive laisse de la place pour
    /// poser un point « du jour » avant `now` — `HealthStore.records` borne à
    /// `startDate < to`, un échantillon posé exactement à `now` serait exclu.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    func test_theSevenAnalysisViewModels_loadOnIOSAgainstAnEmptyStore() throws {
        let store = try HealthStore(path: ":memory:")
        let routes = RouteStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let now = fixedNow

        try DashboardViewModel(store: store, resolver: resolver, now: { now }).load()
        try ActivityViewModel(store: store, resolver: resolver, now: { now }).load()
        try SleepViewModel(store: store, resolver: resolver, now: { now }).load()
        try TrendsViewModel(store: store, resolver: resolver, now: { now }).load(period: .sixMonths)
        try CorrelationsViewModel(store: store, resolver: resolver, now: { now }).load()
        try TrainingViewModel(store: store, now: { now }).load()
        try WorkoutsViewModel(store: store, routeStore: routes, now: { now }).load()
    }

    /// Le tableau de bord partagé doit produire son score de forme sur une base
    /// sans la moindre pesée — c'est l'état de l'iPhone jusqu'au SP5 — sans
    /// fabriquer d'alerte de poids au passage. `DashboardViewModel` ne publie
    /// pas cette alerte : il passe `WeightEngine.safetyAlert` à
    /// `DailyAdviceEngine`, qui substitue le message de la première alerte
    /// `.warning` au message générique du palier. C'est donc le conseil du jour
    /// qu'il faut observer.
    func test_dashboard_onAStoreWithoutAnyWeight_scoresReadinessAndRaisesNoWeightAlert() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        // Baseline de FC repos : 10 jours à 60 bpm, puis 66 aujourd'hui (+10 %).
        var records: [HealthRecord] = []
        for day in 1...10 {
            let date = calendar.date(byAdding: .day, value: -day, to: now)!
            records.append(HealthRecord(type: "HKQuantityTypeIdentifierRestingHeartRate",
                                        sourceName: "Watch", device: nil, unit: "count/min",
                                        value: 60, startDate: date,
                                        endDate: date.addingTimeInterval(300), creationDate: date))
        }
        let todayMeasurement = now.addingTimeInterval(-3600)
        records.append(HealthRecord(type: "HKQuantityTypeIdentifierRestingHeartRate",
                                     sourceName: "Watch", device: nil, unit: "count/min",
                                     value: 66, startDate: todayMeasurement,
                                     endDate: todayMeasurement.addingTimeInterval(300),
                                     creationDate: todayMeasurement))
        try store.insertRecords(records)

        let viewModel = DashboardViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertNotNil(viewModel.readiness,
                        "le score de forme ne dépend pas du poids et doit être calculé")
        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                       "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.",
                       "sans pesée en base, le conseil du jour doit rester le message générique du palier : "
                       + "une alerte de poids le remplacerait")
    }
}
