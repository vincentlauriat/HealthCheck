import XCTest
import Network
@testable import HealthCheckCompanion

final class BonjourEndpointProviderTests: XCTestCase {
    func test_ipv4Host_formatsAsIs_andBuildsValidURL() {
        let host = NWEndpoint.Host("192.168.1.5")
        let formatted = BonjourEndpointProvider.urlHost(for: host)
        XCTAssertEqual(formatted, "192.168.1.5")

        let url = URL(string: "http://\(formatted):8080/batch")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(url?.host, "192.168.1.5")
    }

    func test_ipv6LinkLocalHost_bracketsAndPercentEncodesScope_andBuildsValidURL() {
        let host = NWEndpoint.Host("fe80::1c%en0")
        let formatted = BonjourEndpointProvider.urlHost(for: host)
        XCTAssertTrue(formatted.hasPrefix("["))
        XCTAssertTrue(formatted.hasSuffix("]"))
        XCTAssertTrue(formatted.contains("%25en0"))

        let url = URL(string: "http://\(formatted):8080/batch")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.port, 8080)
        // Foundation normalise l'affichage du host IPv6 (crochets retirés,
        // %25 potentiellement redécodé) : on vérifie la forme réellement
        // envoyée sur le fil via absoluteString plutôt que `url.host`.
        XCTAssertTrue(url?.absoluteString.contains(formatted) ?? false)
    }

    func test_nameHost_passthrough_andBuildsValidURL() {
        let host = NWEndpoint.Host.name("macbook.local", nil)
        let formatted = BonjourEndpointProvider.urlHost(for: host)
        XCTAssertEqual(formatted, "macbook.local")

        let url = URL(string: "http://\(formatted):8080/batch")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.port, 8080)
        XCTAssertEqual(url?.host, "macbook.local")
    }
}
