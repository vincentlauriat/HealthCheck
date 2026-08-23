import XCTest
@testable import HealthCheckCompanion

/// Stub URLProtocol : rejoue une réponse enregistrée et capture la requête.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct FixedEndpoint: MacEndpointProviding {
    let endpoint: (host: String, port: UInt16)?
    func currentEndpoint() async -> (host: String, port: UInt16)? { endpoint }
}

final class MacClientTests: XCTestCase {
    private var tokenStore: KeychainTokenStore!
    private var client: MacClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        tokenStore = KeychainTokenStore(service: "test-\(UUID().uuidString)")
        client = MacClient(endpointProvider: FixedEndpoint(endpoint: ("127.0.0.1", 8080)),
                           tokenStore: tokenStore,
                           session: URLSession(configuration: config))
    }

    override func tearDown() { tokenStore.clear(); StubURLProtocol.handler = nil }

    func test_pair_success_storesToken_andTargetsPairPath() async throws {
        StubURLProtocol.handler = { _ in
            (200, try! ExchangeCoding.encoder.encode(PairResponse(token: "feedface")))
        }
        try await client.pair(code: "123456")
        XCTAssertEqual(tokenStore.currentToken(), "feedface")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/pair")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func test_pair_401_throwsPairingRejected_andStoresNothing() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        do { try await client.pair(code: "000000"); XCTFail("aurait dû lever") }
        catch let error as MacClientError { XCTAssertEqual(error, .pairingRejected) }
        catch { XCTFail("mauvaise erreur: \(error)") }
        XCTAssertNil(tokenStore.currentToken())
    }

    func test_push_sendsBearer_decodesInserted() async throws {
        try tokenStore.save(token: "cafe01")
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cafe01")
            return (200, try! ExchangeCoding.encoder.encode(BatchResponse(inserted: 3)))
        }
        let inserted = try await client.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))
        XCTAssertEqual(inserted, 3)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/batch")
    }

    func test_push_401_throwsUnauthorized_500_throwsServerError() async throws {
        try tokenStore.save(token: "cafe01")
        StubURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await client.push(batch: ExchangeBatch(records: [], sleep: [], workouts: [])); XCTFail() }
        catch let error as MacClientError { XCTAssertEqual(error, .unauthorized) }

        StubURLProtocol.handler = { _ in (500, Data()) }
        do { _ = try await client.push(batch: ExchangeBatch(records: [], sleep: [], workouts: [])); XCTFail() }
        catch let error as MacClientError { XCTAssertEqual(error, .serverError(500)) }
    }

    func test_noEndpoint_throwsUnreachable() async {
        let offline = MacClient(endpointProvider: FixedEndpoint(endpoint: nil),
                                tokenStore: tokenStore, session: .shared)
        do { _ = try await offline.status(); XCTFail() }
        catch let error as MacClientError { XCTAssertEqual(error, .unreachable) }
        catch { XCTFail("mauvaise erreur: \(error)") }
    }
}
