import XCTest
import GRDB
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
        // sample_export.xml has 3 records followed by 1 workout, in that order.
        let fixtureURL = Bundle(for: Self.self).url(forResource: "sample_export", withExtension: "zip")!

        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthCheckImporterTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dbDir.path)
            try? FileManager.default.removeItem(at: dbDir)
        }

        let store = try HealthStore(path: dbDir.appendingPathComponent("test.sqlite").path)
        // batchSize: 1 makes every record trigger a flush attempt as soon as it's seen.
        let importer = HealthExportImporter(store: store, batchSize: 1)

        // Make the directory read-only so SQLite can't create its rollback-journal
        // file: the very first mid-stream flush (record #1) fails for real, no mock.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dbDir.path)

        // `progress` fires after a record is buffered but before its flush attempt,
        // so restoring write access when count == 2 lets every later write (record
        // #2 onward, including the final flush) succeed. This isolates a failure
        // that happens ONLY mid-stream, with the rest of the import succeeding —
        // exactly the case the old `try? flushRecords()` used to swallow silently,
        // letting importZip return a plausible-but-wrong summary instead of throwing.
        XCTAssertThrowsError(
            try importer.importZip(at: fixtureURL, progress: { count in
                if count == 2 {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dbDir.path)
                }
            })
        ) { error in
            XCTAssertTrue(error is DatabaseError, "expected the underlying store error to surface, got \(error)")
        }
    }
}
