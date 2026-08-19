import XCTest
@testable import HealthCheck

final class HealthExportParserTests: XCTestCase {
    private var fixtureURL: URL {
        Bundle(for: Self.self).url(forResource: "sample_export", withExtension: "xml")!
    }

    func test_parse_extractsRecordsAndWorkouts() throws {
        var records: [HealthRecord] = []
        var workouts: [Workout] = []

        try HealthExportParser().parse(
            fileURL: fixtureURL,
            onRecord: { records.append($0) },
            onWorkout: { workouts.append($0) }
        )

        XCTAssertEqual(records.count, 3, "including the unknown future record type, which must not crash the parser")
        XCTAssertEqual(workouts.count, 1)

        let steps = records.filter { $0.type == "HKQuantityTypeIdentifierStepCount" }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.first(where: { $0.sourceName == "iPhone" })?.value, 120)
        XCTAssertEqual(steps.first(where: { $0.sourceName == "Watch" })?.value, 118)

        XCTAssertEqual(workouts.first?.routeFileName, "route_2026-08-18_1.gpx")
    }
}
