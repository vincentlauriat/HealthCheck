import XCTest
@testable import HealthCheckCompanion

final class LocalStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_init_createsDirectoryAndUsableStore() throws {
        let local = try LocalStore(applicationSupportDirectory: tempDir)
        let start = Date(timeIntervalSince1970: 1_755_900_000)
        let batch = ExchangeBatch(
            records: [ExchangeRecord(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch",
                device: nil, unit: "count", value: 42, startDate: start,
                endDate: start.addingTimeInterval(300), creationDate: nil)],
            sleep: [], workouts: [])

        XCTAssertEqual(try local.importer.ingest(batch), 1)
        let stored = try local.healthStore.records(
            type: "HKQuantityTypeIdentifierStepCount",
            from: start.addingTimeInterval(-1), to: start.addingTimeInterval(3600))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.value, 42)
    }

    func test_init_persistsDatabaseFileInGivenDirectory() throws {
        _ = try LocalStore(applicationSupportDirectory: tempDir)
        let dbPath = tempDir.appendingPathComponent("health.sqlite").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    func test_noOpImporter_alwaysReturnsZero_neverThrows() throws {
        let importer = NoOpImporter()
        XCTAssertEqual(try importer.ingest(ExchangeBatch(records: [], sleep: [], workouts: [])), 0)
    }
}
