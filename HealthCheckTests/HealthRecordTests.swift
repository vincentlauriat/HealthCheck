import XCTest
@testable import HealthCheck

final class HealthRecordTests: XCTestCase {
    private func makeRecord(value: Double = 120, sourceName: String = "iPhone") -> HealthRecord {
        HealthRecord(
            type: "HKQuantityTypeIdentifierStepCount",
            sourceName: sourceName,
            device: "iPhone14,2",
            unit: "count",
            value: value,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_300),
            creationDate: Date(timeIntervalSince1970: 1_700_000_300)
        )
    }

    func test_dedupKey_isStableForIdenticalRecords() {
        XCTAssertEqual(makeRecord().dedupKey, makeRecord().dedupKey)
    }

    func test_dedupKey_differsWhenValueDiffers() {
        XCTAssertNotEqual(makeRecord(value: 120).dedupKey, makeRecord(value: 121).dedupKey)
    }

    func test_dedupKey_differsWhenSourceDiffers() {
        XCTAssertNotEqual(makeRecord(sourceName: "iPhone").dedupKey, makeRecord(sourceName: "Watch").dedupKey)
    }
}
