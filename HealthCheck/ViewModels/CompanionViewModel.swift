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
        let server = SyncServer(router: router) { [weak self] inserted in
            Task { @MainActor [weak self] in self?.didInsert(rows: inserted) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            // Pas de port dispo : la carte restera « serveur arrêté », le
            // reste de l'app fonctionne — pas de crash pour un listener.
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
        isPaired = tokenStore.currentToken() != nil
        pairingCode = nil // un appairage réussi ferme la fenêtre
        lastSyncDate = Date()
        defaults.set(lastSyncDate, forKey: Self.lastSyncKey)
        syncGeneration += 1
    }
}
