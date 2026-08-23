import Foundation

protocol Syncing {
    func syncAll() async -> SyncReport
}

protocol Pairing {
    func pair(code: String) async throws
}

extension SyncEngine: Syncing {}
extension MacClient: Pairing {}

/// État de l'unique écran. Tout est injectable : moteur, appairage, jeton.
@MainActor
final class CompanionViewModel: ObservableObject {
    @Published private(set) var isPaired: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastReportSummary: String?
    @Published var errorMessage: String?

    private static let lastSyncKey = "companionLastSyncDate"

    private let engine: Syncing
    private let pairer: Pairing
    private let tokenStore: KeychainTokenStore
    private let defaults: UserDefaults

    init(engine: Syncing, pairer: Pairing, tokenStore: KeychainTokenStore,
         defaults: UserDefaults = .standard) {
        self.engine = engine
        self.pairer = pairer
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.isPaired = tokenStore.currentToken() != nil
        self.lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    func refreshPairedState() {
        isPaired = tokenStore.currentToken() != nil
    }

    func submitPairingCode(_ code: String) async {
        errorMessage = nil
        do {
            try await pairer.pair(code: code)
            refreshPairedState()
        } catch MacClientError.pairingRejected {
            errorMessage = "Code refusé. Vérifiez le code affiché sur votre Mac (il expire après 2 minutes)."
        } catch MacClientError.unreachable {
            errorMessage = "Mac introuvable. Vérifiez que HealthCheck est ouvert sur votre Mac et que les deux appareils sont sur le même réseau."
        } catch {
            errorMessage = "Échec de l'appairage : \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        let report = await engine.syncAll()
        isSyncing = false

        if report.needsPairing {
            // Jeton invalidé côté Mac (ré-appairage là-bas) : on repart proprement.
            tokenStore.clear()
            isPaired = false
            errorMessage = "Le Mac ne reconnaît plus cet iPhone. Refaites l'appairage."
            return
        }
        if !report.failedTypes.isEmpty && report.pushedSamples == 0 {
            errorMessage = "Mac injoignable — vos données attendent, rien n'est perdu."
            return
        }
        lastSyncDate = Date()
        defaults.set(lastSyncDate, forKey: Self.lastSyncKey)
        lastReportSummary = "\(report.pushedSamples) échantillons envoyés, \(report.insertedRows) nouveaux"
    }
}
