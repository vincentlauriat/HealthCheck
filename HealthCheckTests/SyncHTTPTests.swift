import XCTest
@testable import HealthCheck

final class SyncHTTPTests: XCTestCase {
    private func raw(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    func test_parse_getWithBearer() {
        let req = SyncHTTPRequest.parse(raw("GET /status HTTP/1.1\nHost: mac\nAuthorization: Bearer abc123\n\n"))
        XCTAssertEqual(req?.method, "GET")
        XCTAssertEqual(req?.path, "/status")
        XCTAssertEqual(req?.bearerToken, "abc123")
        XCTAssertEqual(req?.body.count, 0)
    }

    func test_parse_postWithBody_headerCaseInsensitive() {
        let req = SyncHTTPRequest.parse(raw("POST /pair HTTP/1.1\ncontent-length: 16\n\n{\"code\":\"123456\"}"))
        XCTAssertEqual(req?.method, "POST")
        // 16 octets demandés : le corps est tronqué à Content-Length.
        XCTAssertEqual(req?.body, Data("{\"code\":\"123456\"".utf8))
    }

    func test_parse_rejectsGarbage() {
        XCTAssertNil(SyncHTTPRequest.parse(Data("pas du HTTP".utf8)))
        XCTAssertNil(SyncHTTPRequest.parse(Data()))
    }

    func test_expectedTotalLength_waitsForFullBody() {
        let partial = raw("POST /batch HTTP/1.1\nContent-Length: 100\n\n{\"rec")
        let expected = SyncHTTPRequest.expectedTotalLength(partial)
        // longueur en-têtes (jusqu'à CRLFCRLF inclus) + 100
        let headerLength = raw("POST /batch HTTP/1.1\nContent-Length: 100\n\n").count
        XCTAssertEqual(expected, headerLength + 100)
        // Avant la fin des en-têtes : impossible de savoir → nil
        XCTAssertNil(SyncHTTPRequest.expectedTotalLength(Data("POST /ba".utf8)))
    }

    func test_response_buildsStatusLineAndJSON() {
        let body = Data("{\"ok\":true}".utf8)
        let resp = String(data: SyncHTTPResponse.make(status: 200, json: body), encoding: .utf8)!
        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(resp.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(resp.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(resp.hasSuffix("\r\n\r\n{\"ok\":true}"))
        XCTAssertTrue(String(data: SyncHTTPResponse.make(status: 401), encoding: .utf8)!.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }

    // Edge-case regression tests (critical security fix)
    func test_parse_negativeContentLength_doesNotCrash() {
        // Content-Length: -1 must not crash; body should be empty.
        let req = SyncHTTPRequest.parse(raw("POST /sync HTTP/1.1\nContent-Length: -1\n\nhello"))
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.body.count, 0) // negative length clamped to 0
    }

    func test_expectedTotalLength_negativeContentLength_clamped() {
        let partial = raw("POST /sync HTTP/1.1\nContent-Length: -5\n\nhello")
        let expected = SyncHTTPRequest.expectedTotalLength(partial)
        let headerLength = raw("POST /sync HTTP/1.1\nContent-Length: -5\n\n").count
        XCTAssertEqual(expected, headerLength) // negative clamped to 0
    }

    func test_parse_missingContentLength_defaultsToEmpty() {
        // POST without Content-Length → body empty (not EOF)
        let req = SyncHTTPRequest.parse(raw("POST /pair HTTP/1.1\n\n{\"code\":\"123456\"}"))
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.body.count, 0)
    }

    func test_parse_contentLengthZeroWithTrailingBytes() {
        // Content-Length: 0 → body empty, even if bytes follow
        let req = SyncHTTPRequest.parse(raw("POST /pair HTTP/1.1\nContent-Length: 0\n\nextra"))
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.body.count, 0)
    }

    func test_parse_nonNumericContentLength_defaultsToEmpty() {
        // Content-Length: abc → treated as absent/invalid, body empty
        let req = SyncHTTPRequest.parse(raw("POST /pair HTTP/1.1\nContent-Length: abc\n\n{\"code\":\"123456\"}"))
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.body.count, 0)
    }
}
