import XCTest
@testable import HealthCheck

final class WeightEngineTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) 09:00")!
    }

    func weight(_ day: String, _ kg: Double) -> TrendPoint {
        TrendPoint(date: date(day), value: kg)
    }

    // MARK: - trend
    // today = 2026-08-23. Recent window = 2026-08-10..2026-08-23 (14 days).
    // Prior window = 2026-07-27..2026-08-09 (the 14 days before that).

    func test_trend_nilWhenRecentWindowHasNoSample() {
        let weights = [weight("2026-07-30", 70.0)] // only in the prior window
        XCTAssertNil(WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trend_nilWhenPriorWindowHasNoSample() {
        let weights = [weight("2026-08-15", 70.0)] // only in the recent window
        XCTAssertNil(WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trend_stableWhenDeltaClearlyWithinNoiseThreshold() {
        // delta = 0.05, clearly under stableNoiseThresholdKg (0.15)
        let weights = [weight("2026-08-15", 70.05), weight("2026-07-30", 70.0)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.direction, .stable)
    }

    func test_trend_losingWhenDeltaClearlyBeyondNoiseThreshold() {
        // delta = -0.4, clearly beyond stableNoiseThresholdKg (0.15)
        let weights = [weight("2026-08-15", 69.6), weight("2026-07-30", 70.0)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.direction, .losing)
    }

    func test_trend_gainingWhenDeltaClearlyBeyondNoiseThreshold() {
        let weights = [weight("2026-08-15", 70.4), weight("2026-07-30", 70.0)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.direction, .gaining)
    }

    func test_trend_weeklyRateIsHalfTheAverageDeltaBetweenTheTwoWindows() {
        // delta = -1.4 over the 2-week gap between window centers -> -0.7/week
        let weights = [weight("2026-08-15", 70.0), weight("2026-07-30", 71.4)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.weeklyRateKg ?? .nan, -0.7, accuracy: 0.001)
    }

    // MARK: - trajectory

    private func trend(recentAvg: Double, weeklyRate: Double) -> WeightTrend {
        WeightTrend(recentAverageKg: recentAvg, priorAverageKg: recentAvg - weeklyRate * 2,
                   weeklyRateKg: weeklyRate,
                   direction: weeklyRate > 0 ? .gaining : (weeklyRate < 0 ? .losing : .stable))
    }

    private func goal(_ targetKg: Double, daysFromToday: Int) -> WeightGoal {
        let today = date("2026-08-23")
        let target = calendar.date(byAdding: .day, value: daysFromToday, to: today)!
        return WeightGoal(id: "g", targetWeightKg: targetKg, targetDate: target, createdAt: today)
    }

    func test_trajectory_nilWithoutGoal() {
        XCTAssertNil(WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2),
                                             goal: nil, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trajectory_nilWhenTargetDateHasPassed() {
        let g = goal(71, daysFromToday: -1)
        XCTAssertNil(WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2),
                                             goal: g, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trajectory_onTrackAtExactRequiredRate() {
        // target 71 from 75, 14 days (2 weeks) remaining -> required -2.0 kg/week
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2.0),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
        XCTAssertEqual(result?.requiredWeeklyRateKg ?? .nan, -2.0, accuracy: 0.001)
        XCTAssertEqual(result?.weeksRemaining ?? .nan, 2.0, accuracy: 0.001)
    }

    func test_trajectory_onTrackNearUpperTolerance() {
        // ratio = 1.19, clearly under the 1.20 tolerance ceiling
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2.38),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
    }

    func test_trajectory_tooFastClearlyPastUpperTolerance() {
        // ratio = 1.21, clearly over the 1.20 tolerance ceiling
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2.42),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .tooFast)
    }

    func test_trajectory_onTrackNearLowerTolerance() {
        // ratio = 0.81, clearly over the 0.80 tolerance floor
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -1.62),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
    }

    func test_trajectory_tooSlowClearlyPastLowerTolerance() {
        // ratio = 0.79, clearly under the 0.80 tolerance floor
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -1.58),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .tooSlow)
    }

    func test_trajectory_tooSlowWhenActuallyMovingTheWrongWay() {
        // required is -2.0 (need to lose), actual is +1.0 (gaining) -> ratio negative
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: 1.0),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .tooSlow)
    }

    func test_trajectory_onTrackWhenAlreadyAtTarget() {
        // targetWeightKg == recentAverageKg -> requiredWeeklyRateKg ~ 0
        let g = goal(75, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: 0.1),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
        XCTAssertEqual(result?.requiredWeeklyRateKg ?? .nan, 0, accuracy: 0.001)
    }

    // MARK: - safetyAlert
    // recentAverageKg = 100 throughout, so weeklyRateKg numerically equals
    // the rate as a percentage of body weight — no separate percent math to
    // get wrong in the fixtures.

    func test_safetyAlert_nilWhenTrendIsNil() {
        XCTAssertNil(WeightEngine.safetyAlert(trend: nil, trainingLoadElevated: false))
    }

    func test_safetyAlert_nilClearlyBelowInfoThreshold() {
        // 0.3 %/week, clearly under safeInfoRatePercent (0.5)
        let t = trend(recentAvg: 100, weeklyRate: 0.3)
        XCTAssertNil(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false))
    }

    func test_safetyAlert_infoClearlyAboveInfoThreshold() {
        // 0.6 %/week, clearly over 0.5, clearly under safeWarningRatePercent (1.0)
        let t = trend(recentAvg: 100, weeklyRate: 0.6)
        XCTAssertEqual(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)?.severity, .info)
    }

    func test_safetyAlert_infoJustBelowWarningThreshold() {
        // 0.9 %/week, clearly under safeWarningRatePercent (1.0)
        let t = trend(recentAvg: 100, weeklyRate: 0.9)
        XCTAssertEqual(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)?.severity, .info)
    }

    func test_safetyAlert_warningClearlyAboveWarningThreshold() {
        // 1.1 %/week, clearly over safeWarningRatePercent (1.0)
        let t = trend(recentAvg: 100, weeklyRate: 1.1)
        XCTAssertEqual(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)?.severity, .warning)
    }

    func test_safetyAlert_messageHardenedWhenTrainingLoadElevated() {
        let t = trend(recentAvg: 100, weeklyRate: 2.0)
        let alert = WeightEngine.safetyAlert(trend: t, trainingLoadElevated: true)
        XCTAssertEqual(alert?.severity, .warning)
        XCTAssertTrue(alert?.message.contains("charge d'entraînement") ?? false,
                      "le message durci doit mentionner la charge d'entraînement")
    }

    func test_safetyAlert_messageNotHardenedWhenTrainingLoadNotElevated() {
        let t = trend(recentAvg: 100, weeklyRate: 2.0)
        let alert = WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)
        XCTAssertEqual(alert?.severity, .warning)
        XCTAssertFalse(alert?.message.contains("charge d'entraînement") ?? true,
                       "sans charge élevée, le message ne doit pas mentionner l'entraînement")
    }
}
