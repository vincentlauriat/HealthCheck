import XCTest
@testable import HealthCheck

final class SyncServerTests: XCTestCase {
    private var tempDir: URL!
    private var tokenStore: CompanionTokenStore!
    private var pairing: PairingManager!
    private var server: SyncServer!
    private var insertedTotals: [Int] = []
    private var pairedCount = 0

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tokenStore = CompanionTokenStore(directory: tempDir)
        pairing = PairingManager(tokenStore: tokenStore, codeGenerator: { "123456" })
        let router = CompanionRouter(
            pairing: pairing,
            tokenStore: tokenStore,
            importer: CompanionImporter(store: try HealthStore(path: ":memory:"),
                                        routeStore: RouteStore(directory: tempDir)),
            appVersion: "1.0.0")
        server = SyncServer(router: router,
                            onInsert: { [weak self] in self?.insertedTotals.append($0) },
                            onPair: { [weak self] in self?.pairedCount += 1 })
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func url(_ path: String) throws -> URL {
        let port = try XCTUnwrap(server.port)
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func test_server_servesStatus_andRejectsBadToken() async throws {
        try server.start()
        try tokenStore.save(token: "tok")

        var ok = URLRequest(url: try url("/status"))
        ok.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: ok)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let payload = try ExchangeCoding.decoder.decode(StatusResponse.self, from: data)
        XCTAssertEqual(payload.app, "HealthCheck")

        var bad = URLRequest(url: try url("/status"))
        bad.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, badResponse) = try await URLSession.shared.data(for: bad)
        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 401)
    }

    func test_server_pairsOverHTTP_andFiresOnPair() async throws {
        try server.start()
        _ = pairing.openWindow()

        var req = URLRequest(url: try url("/pair"))
        req.httpMethod = "POST"
        req.httpBody = try ExchangeCoding.encoder.encode(PairRequest(code: "123456"))
        let (data, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let payload = try ExchangeCoding.decoder.decode(PairResponse.self, from: data)
        XCTAssertEqual(payload.token, tokenStore.currentToken())
        // La réponse n'est envoyée qu'après le passage dans `respond(on:requestData:)`,
        // qui appelle `onPair()` avant `connection.send` — même argument de visibilité
        // que pour `insertedTotals` dans le test `/batch` ci-dessous.
        XCTAssertEqual(pairedCount, 1)
    }

    func test_server_ingestsBatch_andReportsInsertCount() async throws {
        try server.start()
        try tokenStore.save(token: "tok")
        let start = Date(timeIntervalSince1970: 1_755_900_000)
        let batch = ExchangeBatch(records: [ExchangeRecord(
            type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", device: nil,
            unit: "count", value: 500, startDate: start, endDate: start.addingTimeInterval(300),
            creationDate: nil)], sleep: [], workouts: [])

        var req = URLRequest(url: try url("/batch"))
        req.httpMethod = "POST"
        req.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        req.httpBody = try ExchangeCoding.encoder.encode(batch)
        let (data, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try ExchangeCoding.decoder.decode(BatchResponse.self, from: data).inserted, 1)
        XCTAssertEqual(insertedTotals, [1])
    }
}

@MainActor
final class CompanionViewModelTests: XCTestCase {
    func test_pairingLifecycle_andSyncGeneration() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let defaults = UserDefaults(suiteName: "companion-vm-tests-\(UUID().uuidString)")!
        let vm = CompanionViewModel(store: try HealthStore(path: ":memory:"), defaults: defaults,
                                    tokenStore: CompanionTokenStore(directory: tempDir),
                                    routeStore: RouteStore(directory: tempDir))
        XCTAssertFalse(vm.isPaired)
        XCTAssertNil(vm.pairingCode)
        vm.beginPairing()
        XCTAssertNotNil(vm.pairingCode)
        vm.cancelPairing()
        XCTAssertNil(vm.pairingCode)
        XCTAssertEqual(vm.syncGeneration, 0)
    }

    /// Prouve que `didPair()` — appelée par `SyncServer` via `onPair` sur un
    /// `/pair` réussi — reflète bien le jeton fraîchement persisté, sans
    /// dépendre d'un aller-retour HTTP complet dans ce test.
    func test_didPair_reflectsPersistedToken_andClosesWindow() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vm-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let defaults = UserDefaults(suiteName: "companion-vm-pair-tests-\(UUID().uuidString)")!
        let tokenStore = CompanionTokenStore(directory: tempDir)
        let vm = CompanionViewModel(store: try HealthStore(path: ":memory:"), defaults: defaults,
                                    tokenStore: tokenStore, routeStore: RouteStore(directory: tempDir))
        vm.beginPairing()
        XCTAssertNotNil(vm.pairingCode)
        XCTAssertFalse(vm.isPaired)

        try tokenStore.save(token: "freshly-redeemed-token") // ce que PairingManager.redeem ferait
        vm.didPair()

        XCTAssertTrue(vm.isPaired)
        XCTAssertNil(vm.pairingCode)
    }

    /// Prouve que `didInsert(rows:)` — appelée par `SyncServer` via `onInsert`
    /// sur un `/batch` réussi — fait bien progresser `syncGeneration` et
    /// `lastSyncDate`, sans dépendre d'un aller-retour HTTP complet ici.
    func test_didInsert_advancesSyncGeneration_andSetsLastSyncDate() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vm-insert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let defaults = UserDefaults(suiteName: "companion-vm-insert-tests-\(UUID().uuidString)")!
        let vm = CompanionViewModel(store: try HealthStore(path: ":memory:"), defaults: defaults,
                                    tokenStore: CompanionTokenStore(directory: tempDir),
                                    routeStore: RouteStore(directory: tempDir))
        XCTAssertEqual(vm.syncGeneration, 0)
        XCTAssertNil(vm.lastSyncDate)

        vm.didInsert(rows: 1)

        XCTAssertEqual(vm.syncGeneration, 1)
        XCTAssertNotNil(vm.lastSyncDate)
    }
}
