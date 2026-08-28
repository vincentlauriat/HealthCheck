import XCTest
import HealthKit
@testable import HealthCheckCompanion

private final class FakeEngine: Syncing {
    var report = SyncReport()
    var callCount = 0
    func syncAll() async -> SyncReport { callCount += 1; return report }
}

private final class FakePairer: Pairing {
    var shouldSucceed = true
    var lastCode: String?
    let tokenStore: KeychainTokenStore

    init(tokenStore: KeychainTokenStore) {
        self.tokenStore = tokenStore
    }

    func pair(code: String) async throws {
        lastCode = code
        if !shouldSucceed { throw MacClientError.pairingRejected }
        try? tokenStore.save(token: "tok") // reproduit le comportement réel de MacClient.pair
    }
}

private final class FakeTrainingPlanFetcher: TrainingPlanFetching {
    private static let generatedAt = Date(timeIntervalSince1970: 1_777_000_000)

    var plan = TrainingPlanResponse(
        generatedAt: generatedAt,
        goal: nil,
        weeks: [
            TrainingWeekSummary(
                monday: generatedAt,
                role: "Construction",
                targetKm: 24,
                sessions: [
                    TrainingSessionSummary(
                        kind: "Sortie longue",
                        targetText: "10 km",
                        detailText: "120-150 bpm",
                        note: "Allure conversation.",
                        rationale: "Construire l'endurance.",
                        isOptional: false
                    )
                ]
            )
        ],
        message: "Aucun objectif actif"
    )
    var error: Error?
    private(set) var callCount = 0

    func trainingPlan() async throws -> TrainingPlanResponse {
        callCount += 1
        if let error { throw error }
        return plan
    }
}

@MainActor
final class CompanionViewModelTests: XCTestCase {
    private var tokenStore: KeychainTokenStore!
    private var engine: FakeEngine!
    private var pairer: FakePairer!
    private var anchors: AnchorStore!
    private var anchorsDir: URL!
    private var defaults: UserDefaults!
    private var planFetcher: FakeTrainingPlanFetcher!
    private var vm: CompanionViewModel!

    override func setUp() {
        tokenStore = KeychainTokenStore(service: "vm-test-\(UUID().uuidString)")
        engine = FakeEngine()
        pairer = FakePairer(tokenStore: tokenStore)
        anchorsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vm-anchors-\(UUID().uuidString)", isDirectory: true)
        anchors = AnchorStore(directory: anchorsDir)
        defaults = UserDefaults(suiteName: "vm-test-\(UUID().uuidString)")!
        planFetcher = FakeTrainingPlanFetcher()
        vm = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore, anchors: anchors,
                                 planFetcher: planFetcher, defaults: defaults)
    }

    override func tearDown() {
        tokenStore.clear()
        try? FileManager.default.removeItem(at: anchorsDir)
    }

    func test_initialState_unpaired() {
        XCTAssertFalse(vm.isPaired)
        XCTAssertNil(vm.lastSyncDate)
    }

    func test_submitPairingCode_success_flipsPaired() async {
        pairer.shouldSucceed = true
        await vm.submitPairingCode("123456")
        XCTAssertEqual(pairer.lastCode, "123456")
        XCTAssertTrue(vm.isPaired)
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitPairingCode_failure_setsError() async {
        pairer.shouldSucceed = false
        await vm.submitPairingCode("000000")
        XCTAssertFalse(vm.isPaired)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(tokenStore.currentToken()) // rien stocké : isPaired reste faux faute de jeton, pas par chance
    }

    func test_syncNow_success_updatesStateAndDate() async {
        engine.report = SyncReport(pushedSamples: 12, insertedRows: 10, failedTypes: [], needsPairing: false)
        await vm.syncNow()
        XCTAssertEqual(engine.callCount, 1)
        XCTAssertNotNil(vm.lastSyncDate)
        XCTAssertEqual(vm.lastReportSummary, "12 échantillons envoyés, 10 nouveaux")
    }

    func test_initialization_whenAlreadyPaired_restoresCachedTrainingPlan_withoutFetching() async throws {
        try tokenStore.save(token: "tok")
        await vm.refreshTrainingPlan()

        let relaunched = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore,
                                             anchors: anchors, planFetcher: planFetcher, defaults: defaults)
        await Task.yield()

        XCTAssertTrue(relaunched.isPaired)
        XCTAssertEqual(relaunched.trainingPlan, planFetcher.plan)
        XCTAssertEqual(planFetcher.callCount, 1, "le démarrage restaure le cache sans lancer de découverte réseau automatiquement")
    }

    func test_refreshTrainingPlan_success_updatesPlan() async {
        let generatedAt = Date(timeIntervalSince1970: 1_777_000_000)
        planFetcher.plan = TrainingPlanResponse(
            generatedAt: generatedAt,
            goal: TrainingGoalSummary(name: "Trail", raceDate: generatedAt, distanceKm: 21.1, elevationGainM: 600),
            weeks: [TrainingWeekSummary(monday: generatedAt, role: "Construction", targetKm: 30, sessions: [])],
            message: nil
        )

        await vm.refreshTrainingPlan()

        XCTAssertEqual(planFetcher.callCount, 1)
        XCTAssertEqual(vm.trainingPlan, planFetcher.plan)
        XCTAssertNil(vm.errorMessage)
    }

    func test_refreshTrainingPlan_unreachable_preservesCachedPlan() async {
        await vm.refreshTrainingPlan()
        let cached = vm.trainingPlan
        planFetcher.error = MacClientError.unreachable

        await vm.refreshTrainingPlan()

        XCTAssertEqual(vm.trainingPlan, cached)
        XCTAssertNotNil(vm.errorMessage)
    }

    func test_toggleTrainingSessionCompleted_persistsAcrossRelaunch() async {
        await vm.refreshTrainingPlan()
        let week = planFetcher.plan.weeks[0]
        let session = week.sessions[0]
        let id = vm.trainingSessionID(week: week, session: session, index: 0)

        XCTAssertFalse(vm.isTrainingSessionCompleted(id: id))
        vm.toggleTrainingSessionCompleted(id: id)
        XCTAssertTrue(vm.isTrainingSessionCompleted(id: id))

        let relaunched = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore,
                                             anchors: anchors, planFetcher: planFetcher, defaults: defaults)
        await Task.yield()
        XCTAssertTrue(relaunched.isTrainingSessionCompleted(id: id))
    }

    func test_refreshTrainingPlan_unauthorized_keepsPairingToken() async throws {
        try tokenStore.save(token: "tok")
        vm.refreshPairedState()
        planFetcher.error = MacClientError.unauthorized

        await vm.refreshTrainingPlan()

        XCTAssertTrue(vm.isPaired)
        XCTAssertEqual(tokenStore.currentToken(), "tok")
        XCTAssertNotNil(vm.errorMessage)
    }

    func test_syncNow_needsPairing_keepsLocalPairingToken() async {
        try? tokenStore.save(token: "tok")
        vm.refreshPairedState()
        XCTAssertTrue(vm.isPaired)
        engine.report = SyncReport(pushedSamples: 0, insertedRows: 0, failedTypes: ["x"], needsPairing: true)

        await vm.syncNow()

        XCTAssertTrue(vm.isPaired)
        XCTAssertEqual(tokenStore.currentToken(), "tok")
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - C2 — succès partiel / échec complet réseau vs serveur

    func test_syncNow_partialFailure_doesNotStampDate_summaryMentionsFailureCount_setsWarning() async {
        engine.report = SyncReport(pushedSamples: 10, insertedRows: 8, failedTypes: ["sleep"], needsPairing: false)
        await vm.syncNow()
        XCTAssertNil(vm.lastSyncDate, "un échec partiel ne doit pas tamponner une synchro propre")
        XCTAssertNotNil(vm.lastReportSummary)
        XCTAssertTrue(vm.lastReportSummary?.contains("1 type(s) en échec") ?? false,
                      "le résumé doit mentionner le nombre de types en échec, pas seulement contenir un chiffre")
        XCTAssertNotNil(vm.errorMessage, "un état d'avertissement doit rester visible dans l'UI")
    }

    func test_syncNow_allFailed_unreachable_showsUnreachableMessage() async {
        engine.report = SyncReport(pushedSamples: 0, insertedRows: 0, failedTypes: ["steps"],
                                    needsPairing: false, hadServerError: false)
        await vm.syncNow()
        XCTAssertNil(vm.lastSyncDate)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.errorMessage?.localizedCaseInsensitiveContains("injoignable") ?? false)
    }

    func test_syncNow_allFailed_serverRejected_showsRejectedMessage_notUnreachable() async {
        engine.report = SyncReport(pushedSamples: 0, insertedRows: 0, failedTypes: ["steps"],
                                    needsPairing: false, hadServerError: true)
        await vm.syncNow()
        XCTAssertNil(vm.lastSyncDate)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.errorMessage?.localizedCaseInsensitiveContains("injoignable") ?? true,
                        "un rejet serveur n'est pas un Mac injoignable")
        XCTAssertTrue(vm.errorMessage?.localizedCaseInsensitiveContains("refusé") ?? false)
    }

    // MARK: - unpair

    func test_unpair_clearsToken_andFlipsPairedToFalse() async {
        try? tokenStore.save(token: "tok")
        vm.refreshPairedState()
        XCTAssertTrue(vm.isPaired)

        vm.unpair()

        XCTAssertFalse(vm.isPaired)
        XCTAssertNil(tokenStore.currentToken())
    }

    func test_unpair_clearsAnchors() throws {
        try anchors.save(HKQueryAnchor(fromValue: 1), for: "HKQuantityTypeIdentifierStepCount")
        XCTAssertNotNil(anchors.anchor(for: "HKQuantityTypeIdentifierStepCount"))

        vm.unpair()

        XCTAssertNil(anchors.anchor(for: "HKQuantityTypeIdentifierStepCount"),
                      "unpair() doit vider les ancres HealthKit, pas seulement le jeton")
    }

    func test_unpair_resetsLastSyncStamp_andSummary() async {
        engine.report = SyncReport(pushedSamples: 12, insertedRows: 10, failedTypes: [], needsPairing: false)
        await vm.syncNow()
        XCTAssertNotNil(vm.lastSyncDate)
        XCTAssertNotNil(vm.lastReportSummary)
        XCTAssertNotNil(vm.trainingPlan)
        let week = planFetcher.plan.weeks[0]
        let session = week.sessions[0]
        let sessionID = vm.trainingSessionID(week: week, session: session, index: 0)
        vm.toggleTrainingSessionCompleted(id: sessionID)
        XCTAssertTrue(vm.isTrainingSessionCompleted(id: sessionID))

        pairer.shouldSucceed = false
        await vm.submitPairingCode("000000") // laisse un errorMessage résiduel à nettoyer
        XCTAssertNotNil(vm.errorMessage)

        vm.unpair()

        XCTAssertNil(vm.lastSyncDate, "pas de « dernière synchro » périmée à côté d'un état non appairé")
        XCTAssertNil(vm.lastReportSummary)
        XCTAssertNil(vm.trainingPlan)
        XCTAssertFalse(vm.isTrainingSessionCompleted(id: sessionID))
        XCTAssertNil(vm.errorMessage, "pas de bannière d'erreur périmée au-dessus de l'écran d'appairage")

        // Le vrai test : la persistance, pas seulement l'état en mémoire. Un
        // redémarrage de l'app relit lastSyncDate depuis UserDefaults
        // (CompanionViewModel.init) — si unpair() n'efface que le @Published
        // en mémoire, la date périmée réapparaît après relance.
        let relaunched = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore,
                                             anchors: anchors, planFetcher: planFetcher, defaults: defaults)
        await Task.yield()
        XCTAssertNil(relaunched.lastSyncDate,
                      "la date de dernière synchro doit être purgée d'UserDefaults, pas juste de l'état en mémoire")
        XCTAssertNil(relaunched.trainingPlan,
                     "le cache du plan doit être purgé d'UserDefaults, pas juste de l'état en mémoire")
        XCTAssertFalse(relaunched.isTrainingSessionCompleted(id: sessionID),
                       "les coches locales doivent aussi être purgées d'UserDefaults")
    }

    func test_unpair_thenSubmitPairingCode_pairsAgain() async {
        try? tokenStore.save(token: "old-tok")
        vm.refreshPairedState()
        vm.unpair()
        XCTAssertFalse(vm.isPaired)

        pairer.shouldSucceed = true
        await vm.submitPairingCode("654321")

        XCTAssertTrue(vm.isPaired, "l'échappatoire doit mener quelque part : un nouveau code doit ré-appairer")
        XCTAssertEqual(pairer.lastCode, "654321")
    }
}
