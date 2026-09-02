import XCTest
@testable import HealthCheckCompanion

/// Le moteur doit être appelable depuis l'iPhone — c'est tout l'objet de
/// l'extraction — et donner les mêmes chiffres que sur le Mac.
@MainActor
final class PeriodSummaryEngineTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func record(_ type: String, _ value: Double, at date: Date, source: String = "Watch") -> HealthRecord {
        HealthRecord(type: type, sourceName: source, device: nil, unit: nil, value: value,
                     startDate: date, endDate: date.addingTimeInterval(60), creationDate: date)
    }

    func test_today_sumsActivityAndKeepsTheLatestRestingHeartRate() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let morning = calendar.startOfDay(for: now).addingTimeInterval(8 * 3600)
        try store.insertRecords([
            record("HKQuantityTypeIdentifierStepCount", 4000, at: morning),
            record("HKQuantityTypeIdentifierStepCount", 2500, at: morning.addingTimeInterval(3600)),
            record("HKQuantityTypeIdentifierDistanceWalkingRunning", 3.2, at: morning),
            record("HKQuantityTypeIdentifierActiveEnergyBurned", 300, at: morning),
            record("HKQuantityTypeIdentifierAppleExerciseTime", 25, at: morning),
            record("HKQuantityTypeIdentifierRestingHeartRate", 58, at: morning),
            record("HKQuantityTypeIdentifierRestingHeartRate", 55, at: morning.addingTimeInterval(7200))
        ])

        let summary = try PeriodSummaryEngine.today(store: store, resolver: resolver,
                                                    calendar: calendar, now: now)

        XCTAssertEqual(summary.steps, 6500)
        XCTAssertEqual(summary.distanceKm, 3.2, accuracy: 0.001)
        XCTAssertEqual(summary.activeEnergyKcal, 300)
        XCTAssertEqual(summary.exerciseMinutes, 25)
        XCTAssertEqual(summary.restingHeartRate, 55, "la dernière mesure du jour, pas la première")
    }

    func test_weekToDate_comparesToTheSameElapsedPortionOfLastWeek() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)!
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start)!
        let elapsed = now.timeIntervalSince(interval.start)

        try store.insertRecords([
            // Cette semaine, tôt : compté.
            record("HKQuantityTypeIdentifierStepCount", 5000, at: interval.start.addingTimeInterval(3600)),
            // La semaine passée, dans la portion écoulée : compté.
            record("HKQuantityTypeIdentifierStepCount", 3000, at: lastWeekStart.addingTimeInterval(3600)),
            // La semaine passée, APRÈS la portion écoulée : ignoré.
            record("HKQuantityTypeIdentifierStepCount", 9000, at: lastWeekStart.addingTimeInterval(elapsed + 3600))
        ])

        let week = try PeriodSummaryEngine.weekToDate(store: store, resolver: resolver,
                                                      calendar: calendar, now: now)

        XCTAssertEqual(week.thisWeek.steps, 5000)
        XCTAssertEqual(try XCTUnwrap(week.lastWeek).steps, 3000,
                       "la comparaison s'arrête à la portion de semaine déjà écoulée")
    }

    // MARK: - InsightInputsBuilder

    private func wellness(sleepNights: [TrendPoint]) -> WellnessOrchestrator.Result {
        WellnessOrchestrator.Result(
            readiness: nil, vo2Trend: nil,
            loadAssessment: LoadAssessment(acuteKm: 0, chronicWeeklyKm: 0, acwr: nil, alerts: []),
            vo2MaxAlert: nil, hrDaily: [], sleepNights: sleepNights)
    }

    func test_insightInputs_underThreeTrackedNights_leavesTheSleepMeanNil() throws {
        let calendar = Calendar.current
        let now = fixedNow
        let nights = (1...2).map {
            TrendPoint(date: calendar.date(byAdding: .day, value: -$0, to: now)!, value: 8.0)
        }

        let inputs = InsightInputsBuilder.build(wellness: wellness(sleepNights: nights), thisWeek: nil,
                                                lastWeek: nil, weightDelta30d: nil,
                                                calendar: calendar, today: now)

        XCTAssertNil(inputs.sleepHoursMean7,
                     "deux nuits ne suffisent pas : une sieste isolée déclencherait une dette de sommeil")
    }

    func test_insightInputs_withThreeTrackedNights_computesTheSleepMean() throws {
        let calendar = Calendar.current
        let now = fixedNow
        let nights = (1...3).map {
            TrendPoint(date: calendar.date(byAdding: .day, value: -$0, to: now)!, value: 8.0)
        }

        let inputs = InsightInputsBuilder.build(wellness: wellness(sleepNights: nights), thisWeek: nil,
                                                lastWeek: nil, weightDelta30d: nil,
                                                calendar: calendar, today: now)

        XCTAssertEqual(try XCTUnwrap(inputs.sleepHoursMean7), 8.0, accuracy: 0.001)
    }
}
