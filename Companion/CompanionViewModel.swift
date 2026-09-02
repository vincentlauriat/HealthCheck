import Foundation

protocol Syncing {
    func syncAll() async -> SyncReport
}

protocol Pairing {
    func pair(code: String) async throws
}

protocol TrainingPlanFetching {
    func trainingPlan() async throws -> TrainingPlanResponse
}

extension SyncEngine: Syncing {}
extension MacClient: Pairing {}
extension MacClient: TrainingPlanFetching {}

/// État de l'unique écran. Tout est injectable : moteur, appairage, jeton.
@MainActor
final class CompanionViewModel: ObservableObject {
    @Published private(set) var isPaired: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var lastReportSummary: String?
    @Published private(set) var trainingPlan: TrainingPlanResponse?
    @Published private(set) var isLoadingTrainingPlan = false
    @Published private var completedTrainingSessionIDs: Set<String>
    @Published var errorMessage: String?

    private static let lastSyncKey = "companionLastSyncDate"
    private static let trainingPlanCacheKey = "companionTrainingPlanCache"
    private static let completedTrainingSessionIDsKey = "companionCompletedTrainingSessionIDs"

    private let engine: Syncing
    private let pairer: Pairing
    private let planFetcher: TrainingPlanFetching
    private let tokenStore: KeychainTokenStore
    private let anchors: AnchorStore
    private let defaults: UserDefaults

    init(engine: Syncing, pairer: Pairing, tokenStore: KeychainTokenStore, anchors: AnchorStore,
         planFetcher: TrainingPlanFetching, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.pairer = pairer
        self.planFetcher = planFetcher
        self.tokenStore = tokenStore
        self.anchors = anchors
        self.defaults = defaults
        self.isPaired = tokenStore.currentToken() != nil
        self.lastSyncDate = defaults.object(forKey: Self.lastSyncKey) as? Date
        self.trainingPlan = defaults.data(forKey: Self.trainingPlanCacheKey).flatMap(Self.decodeTrainingPlan(from:))
        self.completedTrainingSessionIDs = Set(defaults.stringArray(forKey: Self.completedTrainingSessionIDsKey) ?? [])
    }

    func refreshPairedState() {
        isPaired = tokenStore.currentToken() != nil
    }

    func trainingSessionID(week: TrainingWeekSummary, session: TrainingSessionSummary, index: Int) -> String {
        let weekStamp = Int(week.monday.timeIntervalSince1970)
        return [
            String(weekStamp),
            String(index),
            session.kind,
            session.targetText,
            session.detailText,
            session.note,
            session.rationale,
            String(session.isOptional)
        ].joined(separator: "|")
    }

    func isTrainingSessionCompleted(id: String) -> Bool {
        completedTrainingSessionIDs.contains(id)
    }

    func toggleTrainingSessionCompleted(id: String) {
        if completedTrainingSessionIDs.contains(id) {
            completedTrainingSessionIDs.remove(id)
        } else {
            completedTrainingSessionIDs.insert(id)
        }
        defaults.set(Array(completedTrainingSessionIDs).sorted(), forKey: Self.completedTrainingSessionIDsKey)
    }

    /// Rompt l'appairage depuis l'app, sans dépendre du Mac. Efface le jeton
    /// *et* les ancres HealthKit — les deux, pas seulement le jeton.
    ///
    /// Les ancres sont des curseurs par type qui mémorisent ce qui a déjà été
    /// envoyé. Si elles survivaient à un dépairage, un *nouveau* Mac ne
    /// recevrait que les échantillons créés après la dernière synchro avec
    /// l'ancien — tout l'historique antérieur manquerait silencieusement,
    /// sans rien pour le signaler. Se ré-appairer au même Mac ne coûte qu'une
    /// première synchro plus lente, car son ingestion est idempotente
    /// (dédupliquée sur `dedupKey`). Correction avant vitesse : toujours
    /// tout effacer.
    func unpair() {
        tokenStore.clear()
        anchors.clearAll()
        isPaired = false
        lastSyncDate = nil
        lastReportSummary = nil
        trainingPlan = nil
        completedTrainingSessionIDs = []
        isLoadingTrainingPlan = false
        errorMessage = nil
        defaults.removeObject(forKey: Self.lastSyncKey)
        defaults.removeObject(forKey: Self.trainingPlanCacheKey)
        defaults.removeObject(forKey: Self.completedTrainingSessionIDsKey)
    }

    func submitPairingCode(_ code: String) async {
        errorMessage = nil
        do {
            try await pairer.pair(code: code)
            refreshPairedState()
            await refreshTrainingPlan()
        } catch MacClientError.pairingRejected {
            errorMessage = "Code refusé. Vérifiez le code affiché sur votre Mac (il expire après 2 minutes)."
        } catch MacClientError.unreachable {
            errorMessage = "Mac introuvable. Vérifiez que HealthCheck est ouvert sur votre Mac et que les deux appareils sont sur le même réseau."
        } catch {
            errorMessage = "Échec de l'appairage : \(error.localizedDescription)"
        }
    }

    func refreshTrainingPlan() async {
        guard !isLoadingTrainingPlan else { return }
        isLoadingTrainingPlan = true
        defer { isLoadingTrainingPlan = false }
        do {
            let fetchedPlan = try await planFetcher.trainingPlan()
            trainingPlan = fetchedPlan
            cacheTrainingPlan(fetchedPlan)
            errorMessage = nil
        } catch MacClientError.unauthorized {
            errorMessage = "Plan indisponible : synchronisez depuis l'iPhone ou vérifiez que HealthCheck est ouvert sur le Mac."
        } catch MacClientError.unreachable {
            errorMessage = "Mac injoignable — impossible de récupérer le plan pour l'instant."
        } catch {
            errorMessage = "Plan indisponible : \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        let report = await engine.syncAll()
        isSyncing = false

        if report.needsPairing {
            errorMessage = "Le Mac ne reconnaît pas encore cet iPhone. Ouvrez HealthCheck sur le Mac, puis réessayez ou utilisez Oublier ce Mac pour refaire l'appairage."
            return
        }
        guard !report.failedTypes.isEmpty else {
            // Succès complet : tous les types ont réussi (y compris le cas
            // trivial d'un delta vide).
            lastSyncDate = Date()
            defaults.set(lastSyncDate, forKey: Self.lastSyncKey)
            lastReportSummary = "\(report.pushedSamples) échantillons envoyés, \(report.insertedRows) nouveaux"
            await refreshTrainingPlan()
            return
        }
        if report.pushedSamples == 0 {
            // Échec complet : Mac injoignable (réseau) vs Mac joignable mais
            // requête refusée (serveur) sont deux causes distinctes, donc
            // deux messages distincts.
            errorMessage = report.hadServerError
                ? "Le Mac a refusé l'envoi (erreur serveur). Nouvel essai à la prochaine synchronisation."
                : "Mac injoignable — vos données attendent, rien n'est perdu. Vos conseils, eux, sont calculés sur l'iPhone et restent à jour."
            return
        }
        // Échec partiel : certains types ont réussi, d'autres non. Pas de
        // tampon « synchro propre » tant que tout n'est pas passé — l'ancre
        // des types en échec n'a pas avancé, ils seront relivrés.
        lastReportSummary = "\(report.pushedSamples) échantillons envoyés, \(report.insertedRows) nouveaux — \(report.failedTypes.count) type(s) en échec, nouvel essai à la prochaine synchronisation"
        errorMessage = "Envoi partiel : certaines données n'ont pas pu être transmises au Mac. Nouvel essai au prochain envoi."
    }

    private static func decodeTrainingPlan(from data: Data) -> TrainingPlanResponse? {
        try? ExchangeCoding.decoder.decode(TrainingPlanResponse.self, from: data)
    }

    private func cacheTrainingPlan(_ plan: TrainingPlanResponse) {
        guard let data = try? ExchangeCoding.encoder.encode(plan) else { return }
        defaults.set(data, forKey: Self.trainingPlanCacheKey)
    }
}
