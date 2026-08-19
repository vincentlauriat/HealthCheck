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

    private func makeSleepRecord(sourceName: String, value: String, start: Date, end: Date) -> SleepRecord {
        SleepRecord(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: sourceName,
            device: nil,
            value: value,
            startDate: start,
            endDate: end,
            creationDate: start
        )
    }

    func test_insertSleepRecords_isIdempotentAndQueryable() throws {
        let store = try HealthStore(path: ":memory:")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let records = [
            makeSleepRecord(sourceName: "Watch", value: "HKCategoryValueSleepAnalysisAsleepCore", start: start, end: end)
        ]

        let firstCount = try store.insertSleepRecords(records)
        XCTAssertEqual(firstCount, 1)

        let secondCount = try store.insertSleepRecords(records)
        XCTAssertEqual(secondCount, 0, "re-import must be idempotent")

        let stored = try store.sleepRecords(from: start.addingTimeInterval(-1), to: end.addingTimeInterval(1))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.value, "HKCategoryValueSleepAnalysisAsleepCore")
    }
}
