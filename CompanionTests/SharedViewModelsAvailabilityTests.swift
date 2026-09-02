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
    /// 2026-08-24 04:26 UTC. Fixe : ce dépôt a déjà connu des échecs à minuit.
    private let fixedNow = Date(timeIntervalSince1970: 1_756_009_600)

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
}
