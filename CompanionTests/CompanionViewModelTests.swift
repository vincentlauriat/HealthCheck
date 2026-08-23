import XCTest
@testable import HealthCheckCompanion

private final class FakeEngine: Syncing {
    var report = SyncReport()
    var callCount = 0
    func syncAll() async -> SyncReport { callCount += 1; return report }
}

private final class FakePairer: Pairing {
    var shouldSucceed = true
    var lastCode: String?
    func pair(code: String) async throws {
        lastCode = code
        if !shouldSucceed { throw MacClientError.pairingRejected }
    }
}

@MainActor
final class CompanionViewModelTests: XCTestCase {
    private var tokenStore: KeychainTokenStore!
    private var engine: FakeEngine!
    private var pairer: FakePairer!
    private var vm: CompanionViewModel!

    override func setUp() {
        tokenStore = KeychainTokenStore(service: "vm-test-\(UUID().uuidString)")
        engine = FakeEngine()
        pairer = FakePairer()
        let defaults = UserDefaults(suiteName: "vm-test-\(UUID().uuidString)")!
        vm = CompanionViewModel(engine: engine, pairer: pairer, tokenStore: tokenStore, defaults: defaults)
    }

    override func tearDown() { tokenStore.clear() }

    func test_initialState_unpaired() {
        XCTAssertFalse(vm.isPaired)
        XCTAssertNil(vm.lastSyncDate)
    }

    func test_submitPairingCode_success_flipsPaired() async {
        pairer.shouldSucceed = true
        try? tokenStore.save(token: "tok") // le vrai MacClient.pair stocke ; le fake non, on simule
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
}
