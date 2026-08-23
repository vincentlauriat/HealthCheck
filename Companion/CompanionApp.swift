import SwiftUI
import HealthKit

@main
struct CompanionApp: App {
    private let healthStore: HKHealthStore
    private let reader: HealthKitReaderLive
    private let engine: SyncEngine
    private let client: MacClient
    @StateObject private var viewModel: CompanionViewModel

    init() {
        let store = HKHealthStore() // UNE seule instance pour le reader et le background delivery
        healthStore = store
        let reader = HealthKitReaderLive(store: store)
        let tokenStore = KeychainTokenStore()
        let client = MacClient(endpointProvider: BonjourEndpointProvider(), tokenStore: tokenStore)
        let engine = SyncEngine(reader: reader, pusher: client, anchors: AnchorStore())
        self.reader = reader
        self.client = client
        self.engine = engine
        _viewModel = StateObject(wrappedValue: CompanionViewModel(
            engine: engine, pairer: client, tokenStore: tokenStore))
    }

    var body: some Scene {
        WindowGroup {
            CompanionRootView(viewModel: viewModel)
                .environment(\.locale, Locale(identifier: "fr_FR"))
                .task {
                    guard reader.isAvailable else { return }
                    try? await reader.requestAuthorization()
                    BackgroundSync.register(store: healthStore) { [engine] in
                        _ = await engine.syncAll()
                    }
                }
        }
    }
}
