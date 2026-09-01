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

    /// Renversement assumé du 2026-09-01 : `NoOpImporter` rendait 0 sans lever,
    /// ce qui, depuis que l'ingestion locale a ses propres ancres, ferait
    /// avancer l'ancre sur des données écrites nulle part — perdues pour
    /// toujours. Lever est ce qui garantit la relecture à la passe suivante.
    func test_noOpImporter_throws_soTheLocalAnchorNeverAdvancesOnDataItDroppped() {
        let importer = NoOpImporter()
        XCTAssertThrowsError(try importer.ingest(ExchangeBatch(records: [], sleep: [], workouts: [])))
    }

    func test_init_usesADistinctDirectoryForLocalAnchors() throws {
        let store = try LocalStore(applicationSupportDirectory: tempDir)
        XCTAssertEqual(store.anchors.directory.lastPathComponent, AnchorStore.localSubdirectory)
        XCTAssertNotEqual(store.anchors.directory.lastPathComponent, AnchorStore.macSubdirectory,
                          "partager le répertoire des ancres du Mac annulerait toute la séparation")
    }
}
