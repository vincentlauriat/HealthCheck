import XCTest
@testable import HealthCheck

final class HealthExportImporterTests: XCTestCase {
    func test_importZip_parsesAndStoresRecordsIdempotently() throws {
        let fixtureURL = Bundle(for: Self.self).url(forResource: "sample_export", withExtension: "zip")!
        let store = try HealthStore(path: ":memory:")
        let importer = HealthExportImporter(store: store)

        var progressCalls: [Int] = []
        let firstSummary = try importer.importZip(at: fixtureURL, progress: { progressCalls.append($0) })

        XCTAssertEqual(firstSummary.recordsSeen, 3)
        XCTAssertEqual(firstSummary.recordsInserted, 3)
        XCTAssertEqual(firstSummary.workoutsSeen, 1)
        XCTAssertEqual(firstSummary.workoutsInserted, 1)
        XCTAssertFalse(progressCalls.isEmpty)

        let secondSummary = try importer.importZip(at: fixtureURL, progress: { _ in })
        XCTAssertEqual(secondSummary.recordsInserted, 0, "re-import must be idempotent")
        XCTAssertEqual(secondSummary.workoutsInserted, 0)
    }

    func test_importZip_midStreamStoreFailure_propagatesError() throws {
        let fixtureURL = Bundle(for: Self.self).url(forResource: "sample_export", withExtension: "zip")!

        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthCheckImporterTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dbDir.path)
            try? FileManager.default.removeItem(at: dbDir)
        }

        let store = try HealthStore(path: dbDir.appendingPathComponent("test.sqlite").path)
        // batchSize: 1 forces a flush after the very first record, i.e. mid-stream,
        // well before the parser finishes and the final post-loop flush runs.
        let importer = HealthExportImporter(store: store, batchSize: 1)

        // Removing write permission on the db's directory makes every subsequent
        // write transaction fail (SQLite can no longer create its journal file),
        // simulating a real mid-stream store failure without a mock.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dbDir.path)

        XCTAssertThrowsError(try importer.importZip(at: fixtureURL, progress: { _ in })) { error in
            XCTAssertFalse(error is HealthExportImporterError, "the error must come from the store, not be masked")
        }
    }
}
