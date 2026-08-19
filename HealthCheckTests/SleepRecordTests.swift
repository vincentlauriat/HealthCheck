import XCTest
@testable import HealthCheck

final class SleepRecordTests: XCTestCase {
    private func makeSleepRecord(sourceName: String = "Watch", value: String = "HKCategoryValueSleepAnalysisAsleepCore") -> SleepRecord {
        SleepRecord(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: sourceName,
            device: "Watch7,1",
            value: value,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            creationDate: Date(timeIntervalSince1970: 1_700_003_600)
        )
    }

    func test_dedupKey_isStableForIdenticalSleepRecords() {
        XCTAssertEqual(makeSleepRecord().dedupKey, makeSleepRecord().dedupKey)
    }

    func test_dedupKey_differsWhenValueDiffers() {
        XCTAssertNotEqual(
            makeSleepRecord(value: "HKCategoryValueSleepAnalysisAsleepCore").dedupKey,
            makeSleepRecord(value: "HKCategoryValueSleepAnalysisAwake").dedupKey
        )
    }

    func test_conformsToTimedHealthValue() {
        let record: TimedHealthValue = makeSleepRecord()
        XCTAssertEqual(record.type, "HKCategoryTypeIdentifierSleepAnalysis")
    }
}
