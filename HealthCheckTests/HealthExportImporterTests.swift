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
        XCTAssertEqual(firstSummary.sleepRecordsSeen, 1)
        XCTAssertEqual(firstSummary.sleepRecordsInserted, 1)
        XCTAssertFalse(progressCalls.isEmpty)

        let secondSummary = try importer.importZip(at: fixtureURL, progress: { _ in })
        XCTAssertEqual(secondSummary.recordsInserted, 0, "re-import must be idempotent")
        XCTAssertEqual(secondSummary.workoutsInserted, 0)
        XCTAssertEqual(secondSummary.sleepRecordsInserted, 0)
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

    /// La clé de dédoublonnage d'une séance ne dépend ni de la distance ni de
    /// l'énergie. Un `INSERT OR IGNORE` seul laissait donc à jamais vides les
    /// 1 551 séances importées avant que le parseur n'apprenne à lire
    /// `<WorkoutStatistics>` : corriger le parseur n'aurait rien réparé du
    /// passé. Un import doit compléter ce qui manque — et ne jamais effacer ce
    /// qui est déjà là.
    func test_insertWorkouts_fillsInWhatWasMissingWithoutOverwriting() throws {
        let store = try HealthStore(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_786_859_360)
        func run(distance: Double?, unit: String?, energy: Double?, route: String?) -> Workout {
            Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Apple Watch de Vincent",
                    duration: 26, durationUnit: "min",
                    totalDistance: distance, totalDistanceUnit: unit,
                    totalEnergyBurned: energy, totalEnergyBurnedUnit: energy.map { _ in "kcal" },
                    startDate: start, endDate: start.addingTimeInterval(1560), routeFileName: route)
        }

        // Import d'avant le correctif : ni distance ni énergie.
        let first = try store.insertWorkouts([run(distance: nil, unit: nil, energy: nil, route: nil)])
        XCTAssertEqual(first.inserted, 1)
        XCTAssertEqual(first.enriched, 0)

        // Réimport du même export, cette fois lu correctement.
        let second = try store.insertWorkouts([run(distance: 4.20131, unit: "km", energy: 301.571,
                                                   route: "route.gpx")])
        XCTAssertEqual(second.inserted, 0, "la séance est la même, pas une nouvelle")
        XCTAssertEqual(second.enriched, 1)

        let stored = try XCTUnwrap(store.workouts(from: start.addingTimeInterval(-60),
                                                  to: start.addingTimeInterval(3600)).first)
        XCTAssertEqual(try XCTUnwrap(stored.totalDistance), 4.20131, accuracy: 0.00001)
        XCTAssertEqual(stored.totalDistanceUnit, "km")
        XCTAssertEqual(try XCTUnwrap(stored.totalEnergyBurned), 301.571, accuracy: 0.001)
        XCTAssertEqual(stored.routeFileName, "route.gpx")

        // Un import plus pauvre ne doit rien effacer.
        let third = try store.insertWorkouts([run(distance: nil, unit: nil, energy: nil, route: nil)])
        XCTAssertEqual(third.enriched, 0, "rien à compléter, donc aucune écriture")
        let after = try XCTUnwrap(store.workouts(from: start.addingTimeInterval(-60),
                                                 to: start.addingTimeInterval(3600)).first)
        XCTAssertEqual(try XCTUnwrap(after.totalDistance), 4.20131, accuracy: 0.00001)
        XCTAssertEqual(after.routeFileName, "route.gpx")
    }
}
