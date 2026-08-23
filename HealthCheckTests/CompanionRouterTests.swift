import XCTest
@testable import HealthCheck

final class CompanionRouterTests: XCTestCase {
    private var tempDir: URL!
    private var tokenStore: CompanionTokenStore!
    private var pairing: PairingManager!
    private var router: CompanionRouter!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tokenStore = CompanionTokenStore(directory: tempDir)
        pairing = PairingManager(tokenStore: tokenStore, codeGenerator: { "123456" })
        let importer = CompanionImporter(store: try HealthStore(path: ":memory:"),
                                         routeStore: RouteStore(directory: tempDir))
        router = CompanionRouter(pairing: pairing, tokenStore: tokenStore,
                                 importer: importer, appVersion: "1.0.0")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: Data = Data()) -> SyncHTTPRequest {
        SyncHTTPRequest(method: method, path: path, bearerToken: token, body: body)
    }

    private func status(of response: Data) -> Int {
        let line = String(data: response.prefix(12), encoding: .utf8) ?? ""
        return Int(line.split(separator: " ")[1]) ?? 0
    }

    func test_pair_rightCode_returnsToken() throws {
        _ = pairing.openWindow()
        let body = try ExchangeCoding.encoder.encode(PairRequest(code: "123456"))
        let result = router.handle(request("POST", "/pair", body: body))
        XCTAssertEqual(status(of: result.response), 200)
        let jsonStart = result.response.range(of: Data("\r\n\r\n".utf8))!.upperBound
        let payload = try ExchangeCoding.decoder.decode(PairResponse.self, from: result.response[jsonStart...])
        XCTAssertEqual(payload.token, tokenStore.currentToken())
    }

    func test_pair_wrongCodeOrClosedWindow_is401() throws {
        let body = try ExchangeCoding.encoder.encode(PairRequest(code: "123456"))
        XCTAssertEqual(status(of: router.handle(request("POST", "/pair", body: body)).response), 401)
        _ = pairing.openWindow()
        let bad = try ExchangeCoding.encoder.encode(PairRequest(code: "654321"))
        XCTAssertEqual(status(of: router.handle(request("POST", "/pair", body: bad)).response), 401)
    }

    func test_batch_goodToken_ingests_badToken_401() throws {
        try tokenStore.save(token: "goodtoken")
        let start = Date(timeIntervalSince1970: 1_755_900_000)
        let batch = ExchangeBatch(records: [ExchangeRecord(
            type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", device: nil,
            unit: "count", value: 500, startDate: start, endDate: start.addingTimeInterval(300),
            creationDate: nil)], sleep: [], workouts: [])
        let body = try ExchangeCoding.encoder.encode(batch)

        let ok = router.handle(request("POST", "/batch", token: "goodtoken", body: body))
        XCTAssertEqual(status(of: ok.response), 200)
        XCTAssertEqual(ok.insertedRows, 1)

        let replay = router.handle(request("POST", "/batch", token: "goodtoken", body: body))
        XCTAssertEqual(replay.insertedRows, 0) // idempotent

        XCTAssertEqual(status(of: router.handle(request("POST", "/batch", token: "wrong", body: body)).response), 401)
        XCTAssertEqual(status(of: router.handle(request("POST", "/batch", body: body)).response), 401)
    }

    func test_batch_malformedJSON_is400() throws {
        try tokenStore.save(token: "goodtoken")
        let result = router.handle(request("POST", "/batch", token: "goodtoken", body: Data("{oops".utf8)))
        XCTAssertEqual(status(of: result.response), 400)
        XCTAssertEqual(result.insertedRows, 0)
    }

    func test_status_authenticated_unknownPath404() throws {
        try tokenStore.save(token: "goodtoken")
        XCTAssertEqual(status(of: router.handle(request("GET", "/status", token: "goodtoken")).response), 200)
        XCTAssertEqual(status(of: router.handle(request("GET", "/status")).response), 401)
        XCTAssertEqual(status(of: router.handle(request("GET", "/nope", token: "goodtoken")).response), 404)
    }
}
