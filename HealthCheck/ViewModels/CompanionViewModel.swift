import Foundation

/// Section « iPhone » de l'écran Données : cycle d'appairage, état du
/// serveur, génération de synchro. Même contrat que `WithingsViewModel` :
/// `syncGeneration` s'incrémente après toute insertion, `ContentView`
/// s'en sert pour rafraîchir les sections.
@MainActor
final class CompanionViewModel: ObservableObject {
    @Published private(set) var isPaired: Bool
    @Published private(set) var pairingCode: String?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncGeneration = 0

    private static let lastSyncKey = "companionLastSyncDate"

    private let pairing: PairingManager
    private let tokenStore: CompanionTokenStore
    private let defaults: UserDefaults
    private var server: SyncServer?
    private let router: CompanionRouter

    /// `tokenStore`/`routeStore` sont injectables pour les tests : les valeurs
    /// par défaut pointent vers Application Support réel, jamais touché en test.
    init(store: HealthStore, defaults: UserDefaults = .standard,
         tokenStore: CompanionTokenStore = CompanionTokenStore(), routeStore: RouteStore = RouteStore()) {
        self.tokenStore = tokenStore
        self.pairing = PairingManager(tokenStore: tokenStore)
        self.defaults = defaults
        self.isPaired = tokenStore.currentToken() != nil
        self.lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        self.router = CompanionRouter(
            pairing: pairing, tokenStore: tokenStore,
            importer: CompanionImporter(store: store, routeStore: routeStore),
            appVersion: version)
    }

    func startServer() {
        guard server == nil else { return }
        let server = SyncServer(
            router: router,
            onInsert: { [weak self] inserted in
                Task { @MainActor [weak self] in self?.didInsert(rows: inserted) }
            },
            onPair: { [weak self] in
                Task { @MainActor [weak self] in self?.didPair() }
            })
        self.server = server
        // `start()` bloque jusqu'à 2 s (attente `.ready`) et le tout premier
        // bind peut déclencher l'invite système d'accès au réseau local —
        // jamais bloquer le MainActor là-dessus, sous peine de geler l'UI.
        Task.detached(priority: .utility) { [weak self] in
            do {
                try server.start()
            } catch {
                // Pas de port dispo : la carte restera « serveur arrêté », le
                // reste de l'app fonctionne — pas de crash pour un listener.
                await MainActor.run { self?.server = nil }
            }
        }
    }

    func beginPairing() {
        pairingCode = pairing.openWindow()
    }

    func cancelPairing() {
        pairing.closeWindow()
        pairingCode = nil
    }

    func unpair() {
        tokenStore.clear()
        isPaired = false
    }

    private func didInsert(rows: Int) {
        lastSyncDate = Date()
        defaults.set(lastSyncDate, forKey: Self.lastSyncKey)
        syncGeneration += 1
    }

    /// Signalé par `SyncServer` sur un `/pair` réussi (jeton déjà persisté par
    /// `PairingManager.redeem`). Interne (non `private`) pour rester testable
    /// directement, sans round-trip HTTP complet dans les tests.
    func didPair() {
        isPaired = tokenStore.currentToken() != nil
        pairingCode = nil // un appairage réussi ferme la fenêtre
    }
}
