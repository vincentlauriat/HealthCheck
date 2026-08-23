import XCTest
import HealthKit
@testable import HealthCheckCompanion

final class PersistenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anchors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_anchorStore_roundTrips_andIsolatesTypes() throws {
        let store = AnchorStore(directory: tempDir)
        XCTAssertNil(store.anchor(for: "HKQuantityTypeIdentifierStepCount"))

        let anchor = HKQueryAnchor(fromValue: 42)
        try store.save(anchor, for: "HKQuantityTypeIdentifierStepCount")
        XCTAssertEqual(store.anchor(for: "HKQuantityTypeIdentifierStepCount"), anchor)
        XCTAssertNil(store.anchor(for: "HKQuantityTypeIdentifierHeartRate")) // isolé par type

        try store.save(HKQueryAnchor(fromValue: 43), for: "HKQuantityTypeIdentifierStepCount")
        XCTAssertEqual(store.anchor(for: "HKQuantityTypeIdentifierStepCount"), HKQueryAnchor(fromValue: 43))

        store.clearAll()
        XCTAssertNil(store.anchor(for: "HKQuantityTypeIdentifierStepCount"))
    }

    func test_anchorStore_corruptFile_readsAsNil() throws {
        let store = AnchorStore(directory: tempDir)
        try Data("pas une archive".utf8).write(to: tempDir.appendingPathComponent("HKQuantityTypeIdentifierStepCount.anchor"))
        XCTAssertNil(store.anchor(for: "HKQuantityTypeIdentifierStepCount"))
    }

    func test_keychain_roundTrip() throws {
        let store = KeychainTokenStore(service: "test-\(UUID().uuidString)")
        XCTAssertNil(store.currentToken())
        try store.save(token: "deadbeef")
        XCTAssertEqual(store.currentToken(), "deadbeef")
        try store.save(token: "cafebabe") // écrasement
        XCTAssertEqual(store.currentToken(), "cafebabe")
        store.clear()
        XCTAssertNil(store.currentToken())
    }
}
