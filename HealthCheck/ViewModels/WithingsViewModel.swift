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
    @Published private(set) var lastSyncDate: Date?
    /// Incrémenté après chaque synchro ayant inséré des données — observé par
    /// ContentView pour recharger les autres écrans.
    @Published private(set) var syncGeneration = 0

    /// En dessous de cet âge, une synchro automatique est inutile.
    static let autoSyncInterval: TimeInterval = 12 * 3600
    private static let lastSyncKey = "withingsLastSyncDate"

    private let store: HealthStore
    private let client: WithingsClient?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(store: HealthStore, client: WithingsClient? = WithingsClient(), defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.client = client
        self.defaults = defaults
        self.now = now
        lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
        if let client {
            status = client.isConnected ? .connected : .disconnected
        } else {
            status = .unconfigured
        }
    }

    /// Décision pure de la synchro automatique, testable sans réseau.
    nonisolated static func shouldAutoSync(lastSync: Date?, now: Date) -> Bool {
        guard let lastSync else { return true }
        return now.timeIntervalSince(lastSync) >= autoSyncInterval
    }

    /// Synchro silencieuse au lancement : uniquement si le compte est
    /// connecté et que la dernière synchro date de plus de 12 h.
    func autoSyncIfNeeded() {
        guard status == .connected, Self.shouldAutoSync(lastSync: lastSyncDate, now: now()) else { return }
        sync()
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
                lastSyncDate = now()
                defaults.set(lastSyncDate, forKey: Self.lastSyncKey)
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
