import XCTest
@testable import HealthCheck

final class HealthScoreEngineTests: XCTestCase {
    private let baseline = [60.0, 60.0, 60.0, 60.0, 60.0, 60.0]

    func test_restingHeartRate_atBaselineScoresFull_aboveBaselinePenalized() {
        XCTAssertEqual(HealthScoreEngine.restingHeartRateScore(today: 60, baseline: baseline)?.score, 100)
        // +5 % → 100 − 0,05 × 600 = 70
        XCTAssertEqual(HealthScoreEngine.restingHeartRateScore(today: 63, baseline: baseline)!.score, 70, accuracy: 0.01)
        // en dessous de la normale : plafonné à 100
        XCTAssertEqual(HealthScoreEngine.restingHeartRateScore(today: 55, baseline: baseline)?.score, 100)
    }

    func test_hrv_belowBaselinePenalized_aboveCappedAt100() {
        let hrvBaseline = [50.0, 50.0, 50.0, 50.0, 50.0]
        // −10 % → 100 − 0,10 × 300 = 70
        XCTAssertEqual(HealthScoreEngine.hrvScore(today: 45, baseline: hrvBaseline)!.score, 70, accuracy: 0.01)
        XCTAssertEqual(HealthScoreEngine.hrvScore(today: 60, baseline: hrvBaseline)?.score, 100)
    }

    func test_sleep_shortNightScoresProportionally() {
        let sleepBaseline = [7.5, 7.5, 7.5, 7.5, 7.5]
        // 6 h / 7,5 h = 80 %
        XCTAssertEqual(HealthScoreEngine.sleepScore(lastNightHours: 6, baseline: sleepBaseline)!.score, 80, accuracy: 0.01)
        XCTAssertEqual(HealthScoreEngine.sleepScore(lastNightHours: 9, baseline: sleepBaseline)?.score, 100)
    }

    func test_insufficientBaselineReturnsNil() {
        XCTAssertNil(HealthScoreEngine.restingHeartRateScore(today: 60, baseline: [60, 60]))
        XCTAssertNil(HealthScoreEngine.sleepScore(lastNightHours: 7, baseline: []))
    }

    func test_readiness_weightsAvailableComponentsAndRenormalizes() {
        let sleep = ScoreComponent(name: "Sommeil", systemImage: "moon.zzz.fill", score: 80, detail: "")
        let hr = ScoreComponent(name: "FC repos", systemImage: "heart.fill", score: 100, detail: "")

        // Sans HRV ni activité : (80 × 0,35 + 100 × 0,30) / 0,65 ≈ 89,23
        let score = HealthScoreEngine.readiness(sleep: sleep, restingHeartRate: hr, hrv: nil, activity: nil)!
        XCTAssertEqual(score.value, (80 * 0.35 + 100 * 0.30) / 0.65, accuracy: 0.01)
        XCTAssertEqual(score.components.count, 2)
        XCTAssertEqual(score.label, "Excellente forme")

        XCTAssertNil(HealthScoreEngine.readiness(sleep: nil, restingHeartRate: nil, hrv: nil, activity: nil))
    }
}

final class InsightsEngineTests: XCTestCase {
    func test_elevatedRestingHR_producesWarningFirst() {
        var inputs = InsightInputs()
        inputs.restingHRMean7 = 63 // +5 % vs 60
        inputs.restingHRMean30 = 60
        inputs.sleepHoursMean7 = 8 // positif

        let insights = InsightsEngine.generate(from: inputs)

        XCTAssertEqual(insights.count, 2)
        XCTAssertEqual(insights.first?.sentiment, .warning, "warnings sort before positives")
        XCTAssertEqual(insights.first?.title, "FC repos élevée")
    }

    func test_sleepDebt_detectedBelowSevenHours() {
        var inputs = InsightInputs()
        inputs.sleepHoursMean7 = 6.2

        let insights = InsightsEngine.generate(from: inputs)

        XCTAssertEqual(insights.first?.title, "Dette de sommeil")
        XCTAssertEqual(insights.first?.sentiment, .warning)
    }

    func test_smallVariationsProduceNoInsight() {
        var inputs = InsightInputs()
        inputs.restingHRMean7 = 60.5 // < 3 %
        inputs.restingHRMean30 = 60
        inputs.stepsThisWeek = 21_000 // < 20 %
        inputs.stepsLastWeek = 20_000
        inputs.weightDelta30d = 0.4 // < 1 kg

        XCTAssertTrue(InsightsEngine.generate(from: inputs).isEmpty)
    }

    func test_vo2Progress_detected() {
        var inputs = InsightInputs()
        inputs.vo2Trend = VO2MaxTrend(recentAverage: 42.5, priorAverage: 40.8, delta: 1.7, verdict: .rising)

        let insights = InsightsEngine.generate(from: inputs)

        XCTAssertEqual(insights.first?.title, "VO₂ max en progression")
        XCTAssertEqual(insights.first?.sentiment, .positive)
        XCTAssertEqual(insights.first?.message, "40.8 → 42.5 ml/kg/min (30 derniers jours vs. les 90 jours précédents) — votre capacité aérobie s'améliore.")
    }

    func test_vo2Stable_producesNoInsight() {
        var inputs = InsightInputs()
        inputs.vo2Trend = VO2MaxTrend(recentAverage: 41.0, priorAverage: 40.8, delta: 0.2, verdict: .stable)

        XCTAssertTrue(InsightsEngine.generate(from: inputs).isEmpty)
    }

    func test_vo2Declining_producesNoInsight() {
        // The insight only ever celebrates progress — a decline is not this
        // engine's concern (the stagnation alert on TrainingViewModel covers it).
        var inputs = InsightInputs()
        inputs.vo2Trend = VO2MaxTrend(recentAverage: 38.0, priorAverage: 40.0, delta: -2.0, verdict: .declining)

        XCTAssertTrue(InsightsEngine.generate(from: inputs).isEmpty)
    }

    func test_vo2NilTrend_producesNoInsight() {
        XCTAssertTrue(InsightsEngine.generate(from: InsightInputs()).isEmpty)
    }
}
