import XCTest
@testable import HealthCheck

final class HealthStoreTests: XCTestCase {
    private func makeRecord(sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(
            type: "HKQuantityTypeIdentifierStepCount",
            sourceName: sourceName,
            device: nil,
            unit: "count",
            value: value,
            startDate: start,
            endDate: start.addingTimeInterval(300),
            creationDate: start
        )
    }

    func test_insertRecords_isIdempotentOnReimport() throws {
        let store = try HealthStore(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(sourceName: "iPhone", value: 120, start: start),
            makeRecord(sourceName: "Watch", value: 118, start: start)
        ]

        let firstImportCount = try store.insertRecords(records)
        XCTAssertEqual(firstImportCount, 2)

        let secondImportCount = try store.insertRecords(records)
        XCTAssertEqual(secondImportCount, 0, "re-importing identical records must insert nothing new")

        let stored = try store.records(
            type: "HKQuantityTypeIdentifierStepCount",
            from: start.addingTimeInterval(-1),
            to: start.addingTimeInterval(301)
        )
        XCTAssertEqual(stored.count, 2)
    }

    func test_insertRecords_addsOnlyNewRowsOnPartialOverlap() throws {
        let store = try HealthStore(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = makeRecord(sourceName: "iPhone", value: 120, start: start)
        _ = try store.insertRecords([existing])

        let batch = [existing, makeRecord(sourceName: "Watch", value: 118, start: start)]
        let insertedCount = try store.insertRecords(batch)
        XCTAssertEqual(insertedCount, 1)
    }
}
