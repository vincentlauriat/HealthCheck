import XCTest
@testable import HealthCheckCompanion

/// Stub URLProtocol : rejoue une réponse enregistrée et capture la requête.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// Simule une requête qui échoue au niveau transport (Mac injoignable) au
    /// lieu de renvoyer une réponse HTTP — nécessaire pour exercer le chemin
    /// `.unreachable` / invalidation du cache d'endpoint (I3).
    nonisolated(unsafe) static var shouldFail = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
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

private final class CountingEndpointProvider: MacEndpointProviding {
    let endpoint: (host: String, port: UInt16)?
    private(set) var callCount = 0
    init(endpoint: (host: String, port: UInt16)?) { self.endpoint = endpoint }
    func currentEndpoint() async -> (host: String, port: UInt16)? {
        callCount += 1
        return endpoint
    }
}

final class MacClientTests: XCTestCase {
    private var tokenStore: KeychainTokenStore!
    private var client: MacClient!

    override func setUp() {
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.shouldFail = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        tokenStore = KeychainTokenStore(service: "test-\(UUID().uuidString)")
        client = MacClient(endpointProvider: FixedEndpoint(endpoint: ("127.0.0.1", 8080)),
                           tokenStore: tokenStore,
                           session: URLSession(configuration: config))
    }

    override func tearDown() {
        tokenStore.clear()
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.shouldFail = false
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

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

    // MARK: - I1 — trousseau illisible sur requête authentifiée

    func test_authenticatedRequest_emptyTokenStore_throwsUnauthorized_withoutPerformingRequest() async {
        // Aucun `save(token:)` : le trousseau est vide.
        do {
            _ = try await client.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))
            XCTFail("aurait dû lever")
        } catch let error as MacClientError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("mauvaise erreur: \(error)")
        }
        XCTAssertNil(StubURLProtocol.lastRequest, "aucune requête ne doit partir sans jeton")
    }

    func test_unauthenticatedRequest_emptyTokenStore_stillSends() async throws {
        // `pair` est non-authentifié : un trousseau vide ne doit pas l'empêcher.
        StubURLProtocol.handler = { _ in
            (200, try! ExchangeCoding.encoder.encode(PairResponse(token: "feedface")))
        }
        try await client.pair(code: "123456")
        XCTAssertNotNil(StubURLProtocol.lastRequest)
    }

    // MARK: - I3 — endpoint mémorisé pour la durée de vie du client

    func test_endpointResolved_oncePerClientLifetime_reusedAcrossRequests() async throws {
        try tokenStore.save(token: "cafe01")
        let provider = CountingEndpointProvider(endpoint: ("127.0.0.1", 8080))
        let cachingClient = MacClient(endpointProvider: provider, tokenStore: tokenStore, session: makeSession())
        StubURLProtocol.handler = { _ in (200, try! ExchangeCoding.encoder.encode(BatchResponse(inserted: 1))) }

        _ = try await cachingClient.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))
        _ = try await cachingClient.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))
        _ = try await cachingClient.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))

        XCTAssertEqual(provider.callCount, 1, "l'endpoint ne doit être résolu qu'une fois puis réutilisé")
    }

    func test_endpointCache_invalidatedOnUnreachable_thenRediscoversOnNextRequest() async throws {
        try tokenStore.save(token: "cafe01")
        let provider = CountingEndpointProvider(endpoint: ("127.0.0.1", 8080))
        let cachingClient = MacClient(endpointProvider: provider, tokenStore: tokenStore, session: makeSession())

        StubURLProtocol.shouldFail = true
        do {
            _ = try await cachingClient.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))
            XCTFail("aurait dû lever .unreachable")
        } catch let error as MacClientError {
            XCTAssertEqual(error, .unreachable)
        }
        XCTAssertEqual(provider.callCount, 1)

        StubURLProtocol.shouldFail = false
        StubURLProtocol.handler = { _ in (200, try! ExchangeCoding.encoder.encode(BatchResponse(inserted: 2))) }
        let inserted = try await cachingClient.push(batch: ExchangeBatch(records: [], sleep: [], workouts: []))

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(provider.callCount, 2, "l'échec réseau doit invalider le cache et forcer une nouvelle découverte")
    }
}
