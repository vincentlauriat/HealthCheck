import XCTest
import HealthKit
@testable import HealthCheckCompanion

final class HKMapperTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_755_900_000)

    private func quantitySample(_ id: HKQuantityTypeIdentifier, unit: HKUnit, value: Double,
                                duration: TimeInterval = 300) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(id),
                         quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: start.addingTimeInterval(duration))
    }

    func test_steps_mapToCountUnit() throws {
        let sample = quantitySample(.stepCount, unit: .count(), value: 500)
        let record = try XCTUnwrap(HKMapper.record(from: sample))
        XCTAssertEqual(record.type, "HKQuantityTypeIdentifierStepCount")
        XCTAssertEqual(record.unit, "count")
        XCTAssertEqual(record.value, 500, accuracy: 0.0001)
        XCTAssertNil(record.device) // ruling : device toujours nil côté compagnon
        XCTAssertEqual(record.startDate, sample.startDate)
    }

    func test_distance_convertsMetersToKilometers() throws {
        let sample = quantitySample(.distanceWalkingRunning, unit: .meter(), value: 2500)
        let record = try XCTUnwrap(HKMapper.record(from: sample))
        XCTAssertEqual(record.unit, "km")
        XCTAssertEqual(record.value, 2.5, accuracy: 0.0001)
    }

    func test_heartRate_and_hrv_and_vo2_units() throws {
        let hr = try XCTUnwrap(HKMapper.record(from: quantitySample(.heartRate,
            unit: HKUnit.count().unitDivided(by: .minute()), value: 62, duration: 0)))
        XCTAssertEqual(hr.unit, "count/min")
        XCTAssertEqual(hr.value, 62, accuracy: 0.0001)

        let hrv = try XCTUnwrap(HKMapper.record(from: quantitySample(.heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli), value: 45, duration: 0)))
        XCTAssertEqual(hrv.unit, "ms")
        XCTAssertEqual(hrv.value, 45, accuracy: 0.0001)

        let vo2Unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        let vo2 = try XCTUnwrap(HKMapper.record(from: quantitySample(.vo2Max, unit: vo2Unit, value: 31.3, duration: 0)))
        XCTAssertEqual(vo2.unit, "mL/min·kg")
        XCTAssertEqual(vo2.value, 31.3, accuracy: 0.0001)
    }

    func test_unknownQuantityType_isDropped() {
        // La température corporelle n'alimente aucun écran : c'est elle,
        // désormais, l'exemple d'un type hors périmètre. `bodyMass` ne l'est
        // plus — le SP5 a renversé la règle « la balance reste Withings ».
        let sample = quantitySample(.bodyTemperature, unit: .degreeCelsius(), value: 36.8, duration: 0)
        XCTAssertNil(HKMapper.record(from: sample))
    }

    /// Les 7 274 lignes déjà en base vont de 0,03 à 0,4527 : une échelle 0-100
    /// ferait diverger l'iPhone du Mac sur le même écran. Et le libellé entre
    /// dans `DedupKey` depuis le 2026-09-03 — s'en écarter recréerait les
    /// doublons qu'on vient de supprimer.
    func test_bodyFatPercentage_isMappedAsAFractionUnderTheStoredLabel() throws {
        let sample = quantitySample(.bodyFatPercentage, unit: .percent(), value: 0.253, duration: 0)
        let record = try XCTUnwrap(HKMapper.record(from: sample))
        XCTAssertEqual(record.value, 0.253, accuracy: 0.0001,
                       "le taux de graisse est stocké en fraction, pas en pourcentage")
        XCTAssertEqual(record.unit, "%")
    }

    func test_bodyMass_andLeanMass_areMappedInKilograms() throws {
        let mass = try XCTUnwrap(HKMapper.record(from: quantitySample(
            .bodyMass, unit: .gramUnit(with: .kilo), value: 88.5, duration: 0)))
        XCTAssertEqual(mass.value, 88.5, accuracy: 0.0001)
        XCTAssertEqual(mass.unit, "kg")

        let lean = try XCTUnwrap(HKMapper.record(from: quantitySample(
            .leanBodyMass, unit: .gramUnit(with: .kilo), value: 65.2, duration: 0)))
        XCTAssertEqual(lean.value, 65.2, accuracy: 0.0001)
        XCTAssertEqual(lean.unit, "kg")
    }

    func test_sleepPhases_mapToZipStrings() throws {
        let deep = HKCategorySample(type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: start, end: start.addingTimeInterval(1800))
        let mapped = try XCTUnwrap(HKMapper.sleep(from: deep))
        XCTAssertEqual(mapped.type, "HKCategoryTypeIdentifierSleepAnalysis")
        XCTAssertEqual(mapped.value, "HKCategoryValueSleepAnalysisAsleepDeep")

        // Tests the wrong-category guard clause (sleepAnalysis type check).
        // The unknown-phase clause (sleepValues dict miss) cannot be tested: HealthKit
        // validates raw values at construction, making it unreachable via public API.
        let otherCategory = HKCategorySample(type: HKCategoryType(.mindfulSession),
            value: 0, start: start, end: start.addingTimeInterval(60))
        XCTAssertNil(HKMapper.sleep(from: otherCategory))
    }

    func test_activityTypeNames_coverKnownTypes_withFallback() {
        XCTAssertEqual(HKMapper.activityTypeName(.running), "HKWorkoutActivityTypeRunning")
        XCTAssertEqual(HKMapper.activityTypeName(.underwaterDiving), "HKWorkoutActivityTypeUnderwaterDiving")
        XCTAssertEqual(HKMapper.activityTypeName(.swimBikeRun), "HKWorkoutActivityTypeSwimBikeRun")
        XCTAssertEqual(HKMapper.activityTypeName(.cricket), "HKWorkoutActivityTypeOther") // hors table → Other
    }
}
