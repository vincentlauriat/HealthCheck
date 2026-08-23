import XCTest
@testable import HealthCheck

final class CompanionPairingTests: XCTestCase {
    private var tempDir: URL!
    private var store: CompanionTokenStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pairing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = CompanionTokenStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func manager(now: @escaping () -> Date, code: String = "123456") -> PairingManager {
        PairingManager(tokenStore: store, now: now, codeGenerator: { code })
    }

    func test_redeem_rightCode_issuesAndPersistsToken() throws {
        var t = Date(timeIntervalSince1970: 0)
        let m = manager(now: { t })
        XCTAssertEqual(m.openWindow(), "123456")
        t += 60
        let token = m.redeem(code: "123456")
        XCTAssertNotNil(token)
        XCTAssertEqual(token?.count, 64) // 32 octets hex
        XCTAssertEqual(store.currentToken(), token)
        XCTAssertFalse(m.isWindowOpen) // un seul échange par fenêtre
    }

    func test_redeem_wrongCode_expiredWindow_noWindow() {
        var t = Date(timeIntervalSince1970: 0)
        let m = manager(now: { t })
        XCTAssertNil(m.redeem(code: "123456")) // aucune fenêtre ouverte
        _ = m.openWindow()
        XCTAssertNil(m.redeem(code: "000000")) // mauvais code
        t += 121 // fenêtre de 120 s expirée
        XCTAssertNil(m.redeem(code: "123456"))
    }

    func test_redeem_rateLimited_afterFiveAttempts() {
        let m = manager(now: { Date(timeIntervalSince1970: 0) })
        _ = m.openWindow()
        for _ in 1...5 { XCTAssertNil(m.redeem(code: "999999")) }
        // 6e tentative : même le bon code est refusé, fenêtre grillée
        XCTAssertNil(m.redeem(code: "123456"))
    }

    func test_tokenFile_hasOwnerOnlyPermissions() throws {
        try store.save(token: "deadbeef")
        let path = tempDir.appendingPathComponent("companion-token.json").path
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(store.currentToken(), "deadbeef")
    }

    func test_randomCode_isSixDigits() {
        let code = PairingManager.randomCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
    }
}
