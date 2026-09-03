import SwiftUI
import HealthKit
import os.log

@main
struct CompanionApp: App {
    private let healthStore: HKHealthStore
    private let reader: HealthKitReaderLive
    private let engine: SyncEngine
    private let client: MacClient
    private let backgroundSyncCoalescer = SyncCoalescer()
    @StateObject private var viewModel: CompanionViewModel
    @StateObject private var advisorViewModel: CompanionAdvisorViewModel
    @StateObject private var activityViewModel: ActivityViewModel
    @StateObject private var sleepViewModel: SleepViewModel
    @StateObject private var trainingViewModel: TrainingViewModel
    @StateObject private var workoutsViewModel: WorkoutsViewModel
    @StateObject private var trendsViewModel: TrendsViewModel
    @StateObject private var correlationsViewModel: CorrelationsViewModel
    @StateObject private var bodyViewModel: BodyViewModel

    init() {
        let store = HKHealthStore() // UNE seule instance pour le reader et le background delivery
        healthStore = store
        let reader = HealthKitReaderLive(store: store)
        let tokenStore = KeychainTokenStore()
        let client = MacClient(endpointProvider: BonjourEndpointProvider(), tokenStore: tokenStore)
        let anchors = AnchorStore()
        let advisorStore: HealthStore
        let localImporter: LocalIngesting
        let localAnchors: AnchorStore
        // Le `RouteStore` du conteneur, jamais celui par défaut : c'est là que
        // `CompanionImporter` écrit les GPX des séances lues dans HealthKit.
        let localRouteStore: RouteStore
        do {
            let localStore = try LocalStore()
            advisorStore = localStore.healthStore
            localImporter = localStore.importer
            localAnchors = localStore.anchors
            localRouteStore = localStore.routeStore
        } catch {
            os_log(.error, "LocalStore indisponible, mode relais seul: %{public}@", String(describing: error))
            advisorStore = HealthStore(unavailable: ())
            localImporter = NoOpImporter()
            // Jamais le répertoire par défaut : ce serait celui du push vers le
            // Mac. `NoOpImporter` lève, donc rien n'y sera jamais écrit.
            localAnchors = AnchorStore(subdirectory: AnchorStore.localSubdirectory)
            // Sans `LocalStore`, il n'y a de toute façon aucune séance à lire.
            localRouteStore = RouteStore()
        }
        let engine = SyncEngine(reader: reader, pusher: client, anchors: anchors,
                                localAnchors: localAnchors, localImporter: localImporter)
        self.reader = reader
        self.client = client
        self.engine = engine
        _viewModel = StateObject(wrappedValue: CompanionViewModel(
            engine: engine, pairer: client, tokenStore: tokenStore, anchors: anchors, planFetcher: client))
        _advisorViewModel = StateObject(wrappedValue: CompanionAdvisorViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
        _activityViewModel = StateObject(wrappedValue: ActivityViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
        _sleepViewModel = StateObject(wrappedValue: SleepViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
        // Pas de résolveur de source ici : la charge se calcule sur la table
        // `workout`, où la déduplication a déjà eu lieu à l'insertion.
        _trainingViewModel = StateObject(wrappedValue: TrainingViewModel(store: advisorStore))
        _workoutsViewModel = StateObject(wrappedValue: WorkoutsViewModel(
            store: advisorStore, routeStore: localRouteStore))
        _trendsViewModel = StateObject(wrappedValue: TrendsViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
        _correlationsViewModel = StateObject(wrappedValue: CorrelationsViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
        _bodyViewModel = StateObject(wrappedValue: BodyViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView(viewModel: viewModel, advisorViewModel: advisorViewModel,
                              activityViewModel: activityViewModel,
                              sleepViewModel: sleepViewModel,
                              trainingViewModel: trainingViewModel,
                              workoutsViewModel: workoutsViewModel,
                              trendsViewModel: trendsViewModel,
                              correlationsViewModel: correlationsViewModel,
                              bodyViewModel: bodyViewModel)
                .environment(\.locale, Locale(identifier: "fr_FR"))
                .task {
                    guard reader.isAvailable else { return }
                    try? await reader.requestAuthorization()
                    // Avant toute chose : remplir la base de l'iPhone. Sans
                    // ceci, rien n'alimentait l'écran Conseils à l'ouverture —
                    // ni le Mac ni l'appairage n'entrent en jeu, donc pas de
                    // découverte Bonjour ni de timeout réseau à subir ici.
                    await engine.ingestLocalData()
                    await advisorViewModel.refresh()
                    BackgroundSync.register(store: healthStore) { [engine, backgroundSyncCoalescer] in
                        await backgroundSyncCoalescer.run {
                            _ = await engine.syncAll()
                        }
                    }
                }
        }
    }
}
