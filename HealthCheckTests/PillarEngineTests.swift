import XCTest
@testable import HealthCheck

final class SleepScoreEngineTests: XCTestCase {
    private let calendar = Calendar.current

    private func segment(_ value: String, start: Date, hours: Double) -> SleepRecord {
        SleepRecord(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: "Watch", device: nil, value: value,
            startDate: start, endDate: start.addingTimeInterval(hours * 3600), creationDate: start
        )
    }

    func test_score_perfectNightScores100() {
        // 8 h dont 1,2 h profond (15 %) et 1,6 h REM (20 %), 0 réveil.
        XCTAssertEqual(SleepScoreEngine.score(asleep: 8, deep: 1.2, rem: 1.6, awakeCount: 0), 100, accuracy: 0.01)
    }

    func test_score_shortFragmentedNightPenalized() {
        // 6 h : durée 37,5 · profond 10 %→13,33 · REM 15 %→15 · 4 réveils→5 = 70,83
        XCTAssertEqual(SleepScoreEngine.score(asleep: 6, deep: 0.6, rem: 0.9, awakeCount: 4), 70.83, accuracy: 0.01)
    }

    func test_score_nightWithoutPhaseDataScoredOnDurationAlone() {
        // Ancienne nuit (tout Unspecified) : 7 h / 8 h = 87,5 — pas plafonnée à 60.
        XCTAssertEqual(SleepScoreEngine.score(asleep: 7, deep: 0, rem: 0, awakeCount: 0), 87.5, accuracy: 0.01)
    }

    func test_summarize_groupsPhasesByNightAndIgnoresInBed() {
        let nightStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: calendar.startOfDay(for: Date()))!
            .addingTimeInterval(-86_400) // hier 23h
        let records = [
            segment("HKCategoryValueSleepAnalysisInBed", start: nightStart.addingTimeInterval(-600), hours: 8.5),
            segment("HKCategoryValueSleepAnalysisAsleepCore", start: nightStart, hours: 4),
            segment("HKCategoryValueSleepAnalysisAsleepDeep", start: nightStart.addingTimeInterval(4 * 3600), hours: 1),
            segment("HKCategoryValueSleepAnalysisAwake", start: nightStart.addingTimeInterval(5 * 3600), hours: 0.1),
            segment("HKCategoryValueSleepAnalysisAsleepREM", start: nightStart.addingTimeInterval(5.1 * 3600), hours: 1.5)
        ]

        let nights = SleepScoreEngine.summarize(records, calendar: calendar)

        XCTAssertEqual(nights.count, 1, "tous les segments appartiennent à la même nuit")
        let night = nights[0]
        XCTAssertEqual(night.asleepHours, 6.5, accuracy: 0.001)
        XCTAssertEqual(night.deepHours, 1.0, accuracy: 0.001)
        XCTAssertEqual(night.remHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(night.awakeCount, 1)
        XCTAssertGreaterThan(night.score, 0)
    }
}

final class StrainEngineTests: XCTestCase {
    private let calendar = Calendar.current

    private func hrSample(_ bpm: Double, start: Date) -> HealthRecord {
        HealthRecord(
            type: "HKQuantityTypeIdentifierHeartRate", sourceName: "Watch", device: nil,
            unit: "count/min", value: bpm,
            startDate: start, endDate: start, creationDate: start
        )
    }

    func test_zoneIndex_boundaries() {
        XCTAssertNil(StrainEngine.zoneIndex(for: 0.45), "sous 50 % de FCmax = repos")
        XCTAssertEqual(StrainEngine.zoneIndex(for: 0.55), 0)
        XCTAssertEqual(StrainEngine.zoneIndex(for: 0.85), 3)
        XCTAssertEqual(StrainEngine.zoneIndex(for: 0.95), 4)
    }

    func test_dayStrains_accumulatesWeightedMinutesIntoScore() {
        let dayStart = calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        // 30 échantillons à 85 % de FCmax (Z4), espacés de 2 min → 60 min Z4.
        let maxHR = 190.0
        let samples = (0..<30).map { hrSample(maxHR * 0.85, start: dayStart.addingTimeInterval(Double($0) * 120)) }

        let strains = StrainEngine.dayStrains(samples: samples, maxHeartRate: maxHR, calendar: calendar)

        XCTAssertEqual(strains.count, 1)
        // 29 intervalles × 2 min + 1 min (dernier) = 59 min en Z4
        XCTAssertEqual(strains[0].zoneMinutes[3], 59, accuracy: 0.01)
        // charge = 59 × 7 = 413 → score = 413/600 × 100 ≈ 68,83
        XCTAssertEqual(strains[0].score, 413.0 / 600.0 * 100.0, accuracy: 0.1)
    }

    func test_dayStrains_capsGapsBetweenSparseSamples() {
        let dayStart = calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let maxHR = 190.0
        // Deux échantillons Z1 séparés d'une heure : le premier vaut 5 min max, pas 60.
        let samples = [
            hrSample(maxHR * 0.55, start: dayStart),
            hrSample(maxHR * 0.55, start: dayStart.addingTimeInterval(3600))
        ]

        let strains = StrainEngine.dayStrains(samples: samples, maxHeartRate: maxHR, calendar: calendar)

        XCTAssertEqual(strains[0].zoneMinutes[0], 6, accuracy: 0.01, "5 min plafonnées + 1 min pour le dernier échantillon")
    }
}

final class HealthStoreAggregateTests: XCTestCase {
    func test_maxValue_returnsMaximumInRange() throws {
        let store = try HealthStore(path: ":memory:")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let record: (Double, Date) -> HealthRecord = { value, start in
            HealthRecord(type: "HKQuantityTypeIdentifierHeartRate", sourceName: "Watch", device: nil, unit: "count/min", value: value, startDate: start, endDate: start, creationDate: start)
        }
        try store.insertRecords([
            record(72, base),
            record(185, base.addingTimeInterval(600)),
            record(95, base.addingTimeInterval(1200))
        ])

        let max = try store.maxValue(type: "HKQuantityTypeIdentifierHeartRate", from: base.addingTimeInterval(-1), to: base.addingTimeInterval(2000))
        XCTAssertEqual(max, 185)

        let outOfRange = try store.maxValue(type: "HKQuantityTypeIdentifierHeartRate", from: base.addingTimeInterval(5000), to: base.addingTimeInterval(9000))
        XCTAssertNil(outOfRange)
    }
}
