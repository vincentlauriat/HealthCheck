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
}
