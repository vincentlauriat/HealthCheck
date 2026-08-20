import Foundation

@MainActor
final class WithingsViewModel: ObservableObject {
    enum Status: Equatable {
        case unconfigured
        case disconnected
        case connecting
        case connected
        case syncing
        case error(String)
    }

    @Published private(set) var status: Status
    @Published private(set) var lastSyncSummary: String?
    /// Incrémenté après chaque synchro ayant inséré des données — observé par
    /// ContentView pour recharger les autres écrans.
    @Published private(set) var syncGeneration = 0

    private let store: HealthStore
    private let client: WithingsClient?

    init(store: HealthStore, client: WithingsClient? = WithingsClient()) {
        self.store = store
        self.client = client
        if let client {
            status = client.isConnected ? .connected : .disconnected
        } else {
            status = .unconfigured
        }
    }

    func connect() {
        guard let client, status == .disconnected || isError else { return }
        status = .connecting
        Task {
            do {
                try await client.connect()
                status = .connected
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func sync() {
        guard let client, status == .connected || isError else { return }
        status = .syncing
        Task {
            do {
                let records = try await client.fetchAllMeasures()
                let inserted = try store.insertRecords(records)
                status = .connected
                lastSyncSummary = "\(records.count) mesures lues, \(inserted) nouvelles"
                if inserted > 0 { syncGeneration += 1 }
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        client?.disconnect()
        if client != nil { status = .disconnected }
    }

    private var isError: Bool {
        if case .error = status { return true }
        return false
    }
}
