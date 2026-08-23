import SwiftUI

@main
struct HealthCheckApp: App {
    private let store: HealthStore
    private let storeError: Error?
    @StateObject private var importViewModel: ImportViewModel
    @StateObject private var dashboardViewModel: DashboardViewModel
    @StateObject private var trendsViewModel: TrendsViewModel
    @StateObject private var sleepViewModel: SleepViewModel
    @StateObject private var activityViewModel: ActivityViewModel
    @StateObject private var bodyViewModel: BodyViewModel
    @StateObject private var withingsViewModel: WithingsViewModel
    @StateObject private var workoutsViewModel: WorkoutsViewModel
    @StateObject private var correlationsViewModel: CorrelationsViewModel
    @StateObject private var companionViewModel: CompanionViewModel

    init() {
        // Base illisible, disque plein, droits refusés : on ne crashe pas au
        // lancement. Le store de repli n'a pas de base sous-jacente et n'est
        // jamais interrogé — `body` affiche l'écran d'erreur à la place de
        // `ContentView`, ce qui garde aussi l'import hors de portée : un
        // export de 844 Mo ne doit pas atterrir dans un store jetable.
        var store: HealthStore
        var failure: Error?
        do {
            guard let appSupportRoot = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { throw StoreStartupError.noApplicationSupportDirectory }

            let directory = appSupportRoot.appendingPathComponent("HealthCheck", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try HealthStore(path: directory.appendingPathComponent("health.sqlite").path)
        } catch {
            store = HealthStore(unavailable: ())
            failure = error
        }
        self.store = store
        self.storeError = failure
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
        _importViewModel = StateObject(wrappedValue: ImportViewModel(importer: HealthExportImporter(store: store)))
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(store: store, resolver: resolver))
        _trendsViewModel = StateObject(wrappedValue: TrendsViewModel(store: store, resolver: resolver))
        _sleepViewModel = StateObject(wrappedValue: SleepViewModel(store: store, resolver: resolver))
        _activityViewModel = StateObject(wrappedValue: ActivityViewModel(store: store, resolver: resolver))
        _bodyViewModel = StateObject(wrappedValue: BodyViewModel(store: store, resolver: resolver))
        _withingsViewModel = StateObject(wrappedValue: WithingsViewModel(store: store))
        _workoutsViewModel = StateObject(wrappedValue: WorkoutsViewModel(store: store))
        _correlationsViewModel = StateObject(wrappedValue: CorrelationsViewModel(store: store, resolver: resolver))
        _companionViewModel = StateObject(wrappedValue: CompanionViewModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            if let storeError {
                StoreErrorView(error: storeError)
            } else {
                ContentView(
                    importViewModel: importViewModel,
                    dashboardViewModel: dashboardViewModel,
                    trendsViewModel: trendsViewModel,
                    sleepViewModel: sleepViewModel,
                    activityViewModel: activityViewModel,
                    bodyViewModel: bodyViewModel,
                    withingsViewModel: withingsViewModel,
                    workoutsViewModel: workoutsViewModel,
                    correlationsViewModel: correlationsViewModel,
                    companionViewModel: companionViewModel
                )
            }
        }
        .environment(\.locale, Locale(identifier: "fr_FR"))
    }
}

enum StoreStartupError: LocalizedError {
    case noApplicationSupportDirectory

    var errorDescription: String? {
        switch self {
        case .noApplicationSupportDirectory:
            return "Dossier Application Support introuvable."
        }
    }
}
