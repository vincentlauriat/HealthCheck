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

    /// Le même échantillon décrit par les deux chemins d'ingestion. L'export XML
    /// d'Apple Santé n'a qu'une précision à la seconde, arrondit la valeur et
    /// porte une description `HKDevice` complète ; la synchro iPhone garde la
    /// pleine précision et laisse `device` vide. Une clé sensible à ces écarts
    /// crée deux lignes pour une seule mesure : 31 409 doublons relevés sur la
    /// base réelle, qui biaisent les moyennes de FC repos, de HRV et de VO2max.
    func test_dedupKey_isTheSameWhicheverImportPathDescribedTheSample() {
        let second = Date(timeIntervalSince1970: 1_755_323_360)
        let fromExport = HealthRecord(
            type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            sourceName: "Apple Watch de Vincent",
            device: "<<HKDevice: 0x7da51ae220>, name:Apple Watch, hardware:Watch7,5>",
            unit: "ms",
            value: 27.3023,
            startDate: second,
            endDate: second.addingTimeInterval(60),
            creationDate: second.addingTimeInterval(62)
        )
        let fromSync = HealthRecord(
            type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            sourceName: "Apple Watch de Vincent",
            device: "",
            unit: "ms",
            value: 27.30228681394361,
            startDate: second.addingTimeInterval(0.622),
            endDate: second.addingTimeInterval(60.111),
            creationDate: nil
        )
        XCTAssertEqual(fromExport.dedupKey, fromSync.dedupKey,
                       "une même mesure ne doit pas produire deux lignes selon son chemin d'import")
    }
}
