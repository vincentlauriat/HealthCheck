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

    init() {
        let store = HKHealthStore() // UNE seule instance pour le reader et le background delivery
        healthStore = store
        let reader = HealthKitReaderLive(store: store)
        let tokenStore = KeychainTokenStore()
        let client = MacClient(endpointProvider: BonjourEndpointProvider(), tokenStore: tokenStore)
        let anchors = AnchorStore()
        let localImporter: LocalIngesting
        do {
            localImporter = try LocalStore().importer
        } catch {
            os_log(.error, "LocalStore indisponible, mode relais seul: %{public}@", String(describing: error))
            localImporter = NoOpImporter()
        }
        let engine = SyncEngine(reader: reader, pusher: client, anchors: anchors, localImporter: localImporter)
        self.reader = reader
        self.client = client
        self.engine = engine
        _viewModel = StateObject(wrappedValue: CompanionViewModel(
            engine: engine, pairer: client, tokenStore: tokenStore, anchors: anchors, planFetcher: client))
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView(viewModel: viewModel)
                .environment(\.locale, Locale(identifier: "fr_FR"))
                .task {
                    guard reader.isAvailable else { return }
                    try? await reader.requestAuthorization()
                    BackgroundSync.register(store: healthStore) { [engine, backgroundSyncCoalescer] in
                        await backgroundSyncCoalescer.run {
                            _ = await engine.syncAll()
                        }
                    }
                }
        }
    }
}
