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

@MainActor
final class CompanionViewModelTests: XCTestCase {
    private var tokenStore: KeychainTokenStore!
    private var engine: FakeEngine!
    private var pairer: FakePairer!
    private var anchors: AnchorStore!
    private var anchorsDir: URL!
    private var defaults: UserDefaults!
    private var vm: CompanionViewModel!

    override func setUp() {
        tokenStore = KeychainTokenStore(service: "vm-test-\(UUID().uuidString)")
        engine = FakeEngine()
        pairer = FakePairer(tokenStore: tokenStore)
        anchorsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vm-anchors-\(UUID().uuidString)", isDirectory: true)
        anchors = AnchorStore(directory: anchorsDir)
        defaults = UserDefaults(suiteName: "vm-test-\(UUID().uuidString)")!
        vm = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore, anchors: anchors,
                                 defaults: defaults)
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

    func test_syncNow_needsPairing_resetsPairedState() async {
        try? tokenStore.save(token: "tok")
        vm.refreshPairedState()
        XCTAssertTrue(vm.isPaired)
        engine.report = SyncReport(pushedSamples: 0, insertedRows: 0, failedTypes: ["x"], needsPairing: true)
        await vm.syncNow()
        XCTAssertFalse(vm.isPaired) // jeton invalidé côté Mac → ré-appairage requis
        XCTAssertNil(tokenStore.currentToken())
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

        pairer.shouldSucceed = false
        await vm.submitPairingCode("000000") // laisse un errorMessage résiduel à nettoyer
        XCTAssertNotNil(vm.errorMessage)

        vm.unpair()

        XCTAssertNil(vm.lastSyncDate, "pas de « dernière synchro » périmée à côté d'un état non appairé")
        XCTAssertNil(vm.lastReportSummary)
        XCTAssertNil(vm.errorMessage, "pas de bannière d'erreur périmée au-dessus de l'écran d'appairage")

        // Le vrai test : la persistance, pas seulement l'état en mémoire. Un
        // redémarrage de l'app relit lastSyncDate depuis UserDefaults
        // (CompanionViewModel.init) — si unpair() n'efface que le @Published
        // en mémoire, la date périmée réapparaît après relance.
        let relaunched = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore,
                                             anchors: anchors, defaults: defaults)
        XCTAssertNil(relaunched.lastSyncDate,
                      "la date de dernière synchro doit être purgée d'UserDefaults, pas juste de l'état en mémoire")
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
