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

    /// Même nuit, deux chemins d'ingestion. Cf. `HealthRecordTests`.
    func test_dedupKey_isTheSameWhicheverImportPathDescribedTheNight() {
        let second = Date(timeIntervalSince1970: 1_755_323_360)
        let fromExport = SleepRecord(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: "Apple Watch de Vincent",
            device: "<<HKDevice: 0x7da51ae220>, name:Apple Watch, hardware:Watch7,5>",
            value: "HKCategoryValueSleepAnalysisAsleepCore",
            startDate: second,
            endDate: second.addingTimeInterval(3600),
            creationDate: second.addingTimeInterval(3602)
        )
        let fromSync = SleepRecord(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: "Apple Watch de Vincent",
            device: "",
            value: "HKCategoryValueSleepAnalysisAsleepCore",
            startDate: second.addingTimeInterval(0.622),
            endDate: second.addingTimeInterval(3600.111),
            creationDate: nil
        )
        XCTAssertEqual(fromExport.dedupKey, fromSync.dedupKey,
                       "une même nuit ne doit pas produire deux lignes selon son chemin d'import")
    }
}
