import XCTest
@testable import HealthCheck

final class TrainingPlannerTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2 // lundi
        return c
    }()

    func date(_ day: String, _ time: String = "09:00") -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(time)")!
    }

    func run(_ day: String, km: Double?, minutes: Double = 30) -> Workout {
        Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                duration: minutes, durationUnit: "min",
                totalDistance: km, totalDistanceUnit: km == nil ? nil : "km",
                totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                startDate: date(day), endDate: date(day).addingTimeInterval(minutes * 60),
                routeFileName: nil)
    }

    func goal(_ raceDay: String = "2026-09-27", km: Double = 17, climb: Double = 400) -> RaceGoal {
        RaceGoal(id: "g1", name: "Paris-Versailles", raceDate: date(raceDay, "10:00"),
                 distanceKm: km, elevationGainM: climb,
                 objective: .finishComfortable, createdAt: date("2026-08-23"))
    }

    /// L'historique réel de Vincent au 2026-08-23 : reprise cette semaine.
    var comebackHistory: [Workout] {
        [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
    }

    func dayString(from day: String, offsetDays: Int) -> String {
        let shifted = calendar.date(byAdding: .day, value: offsetDays, to: date(day))!
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: shifted)
    }

    /// 3 km par jour sur 28 jours : coureur déjà entraîné (21 km/semaine).
    func trainedHistory(perDayKm: Double = 3.0) -> [Workout] {
        (0..<28).map { run(dayString(from: "2026-08-23", offsetDays: -$0), km: perDayKm) }
    }

    // MARK: - Lectures de charge

    func test_distanceKm_usesRealDistanceWhenPresent() {
        XCTAssertEqual(TrainingPlanner.distanceKm(run("2026-08-18", km: 5.0, minutes: 60)),
                       5.0, accuracy: 0.001)
    }

    func test_distanceKm_fallsBackToDurationAtSevenMinutesPerKm() {
        XCTAssertEqual(TrainingPlanner.distanceKm(run("2026-06-13", km: nil, minutes: 35)),
                       5.0, accuracy: 0.001)
    }

    func test_acuteKm_sumsTheLastSevenDaysInclusive() {
        XCTAssertEqual(TrainingPlanner.acuteKm(history: comebackHistory,
                                               today: date("2026-08-23"), calendar: calendar),
                       12.6, accuracy: 0.001)
    }

    func test_acuteKm_excludesRunsOlderThanSevenDays() {
        let history = comebackHistory + [run("2026-08-10", km: 40)]
        XCTAssertEqual(TrainingPlanner.acuteKm(history: history,
                                               today: date("2026-08-23"), calendar: calendar),
                       12.6, accuracy: 0.001)
    }

    func test_chronicWeeklyKm_isTwentyEightDayTotalOverFour() {
        XCTAssertEqual(TrainingPlanner.chronicWeeklyKm(history: comebackHistory,
                                                       today: date("2026-08-23"), calendar: calendar),
                       3.15, accuracy: 0.001)
    }

    // MARK: - Semaine de départ

    func test_plan_currentWeekNearlyOver_isClosingAndRampStartsNextMonday() {
        // 2026-08-23 est un dimanche : il ne reste qu'un jour à la semaine du 08-17.
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(plan.weeks.first?.role, .currentWeekClosing)
        XCTAssertEqual(plan.weeks.first?.monday, calendar.startOfDay(for: date("2026-08-17")))
        XCTAssertEqual(plan.weeks.first?.targetKm, 0)
        XCTAssertEqual(plan.weeks[1].monday, calendar.startOfDay(for: date("2026-08-24")))
        XCTAssertEqual(plan.weeks[1].role, .build)
    }

    func test_plan_currentWeekWithThreeDaysLeft_receivesTargets() {
        // 2026-08-21 est un vendredi : vendredi, samedi, dimanche = 3 jours.
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-21"), calendar: calendar)
        XCTAssertEqual(plan.weeks.first?.role, .build)
        XCTAssertEqual(plan.weeks.first?.monday, calendar.startOfDay(for: date("2026-08-17")))
    }

    func test_daysRemainingInWeek_mondayIsSevenSundayIsOne() {
        XCTAssertEqual(TrainingPlanner.daysRemainingInWeek(from: date("2026-08-17"), calendar: calendar), 7)
        XCTAssertEqual(TrainingPlanner.daysRemainingInWeek(from: date("2026-08-23"), calendar: calendar), 1)
    }

    // MARK: - Volumes

    func test_plan_goldenCase_volumesAndRolesFollowTheRamp() {
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        let planned = plan.weeks.filter { $0.role != .currentWeekClosing }
        XCTAssertEqual(planned.count, 5)
        XCTAssertEqual(planned.map(\.role), [.build, .build, .peak, .taper, .raceWeek])
        for (got, want) in zip(planned.map(\.targetKm), [14.49, 16.66, 19.16, 14.37, 9.58]) {
            XCTAssertEqual(got, want, accuracy: 0.05)
        }
    }

    func test_plan_emptyHistory_startsAtTheTenKilometreFloor() {
        let plan = TrainingPlanner.plan(goal: goal(), history: [], hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(plan.weeks[1].targetKm, 11.5, accuracy: 0.05) // 10 × 1.15
    }

    func test_plan_trainedRunner_usesTheSteadyRampNotTheComebackOne() {
        let plan = TrainingPlanner.plan(goal: goal(), history: trainedHistory(), hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        // chronique 21, aiguë 21 → départ 21 ≥ 17 km → facteur 1.10
        XCTAssertEqual(plan.weeks[1].targetKm, 23.1, accuracy: 0.1)
    }

    func test_plan_peakVolume_isCappedAtOnePointFiveTimesRaceDistance() {
        let plan = TrainingPlanner.plan(goal: goal(), history: trainedHistory(), hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        let peak = plan.weeks.first { $0.role == .peak }!
        XCTAssertLessThanOrEqual(peak.targetKm, 17 * 1.5 + 0.001)
    }

    func test_plan_raceTooClose_isTaperOnlyAndNeverRamps() {
        let plan = TrainingPlanner.plan(goal: goal("2026-09-06"), history: comebackHistory,
                                        hrMax: 190, today: date("2026-08-23"), calendar: calendar)
        let planned = plan.weeks.filter { $0.role != .currentWeekClosing }
        XCTAssertTrue(planned.allSatisfy { $0.role == .taper || $0.role == .raceWeek })
        XCTAssertTrue(planned.allSatisfy { $0.targetKm <= 12.6 * 0.75 + 0.001 })
    }

    func test_plan_isDeterministic() {
        let a = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                     today: date("2026-08-23"), calendar: calendar)
        let b = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                     today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(a, b)
    }

    func test_plan_ignoresNonRunningWorkouts() {
        let swim = Workout(activityType: "HKWorkoutActivityTypeSwimming", sourceName: "Watch",
                           duration: 60, durationUnit: "min", totalDistance: 30,
                           totalDistanceUnit: "km", totalEnergyBurned: nil,
                           totalEnergyBurnedUnit: nil, startDate: date("2026-08-22"),
                           endDate: date("2026-08-22"), routeFileName: nil)
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory + [swim],
                                        hrMax: 190, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(plan.weeks[1].targetKm, 14.49, accuracy: 0.05)
    }

    // MARK: - Séances

    func plannedWeeks(_ today: String = "2026-08-23") -> [PlannedWeek] {
        TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                             today: date(today), calendar: calendar)
            .weeks.filter { $0.role != .currentWeekClosing }
    }

    func test_sessions_goldenCase_longRunChainRespectsTheGrowthCap() {
        let longs = plannedWeeks().map { w in w.sessions.first { $0.kind == .longRun }!.targetKm }
        // base = 5.6 km (plus longue des 14 derniers jours), +2,5 km/semaine max
        for (got, want) in zip(longs, [8.1, 10.0, 11.5, 6.8, 5.75]) {
            XCTAssertEqual(got, want, accuracy: 0.05)
        }
    }

    func test_sessions_longRun_neverExceedsEightyPercentOfRaceDistance() {
        let plan = TrainingPlanner.plan(goal: goal(), history: trainedHistory(perDayKm: 5.0),
                                        hrMax: 190, today: date("2026-08-23"), calendar: calendar)
        for week in plan.weeks {
            if let long = week.sessions.first(where: { $0.kind == .longRun }) {
                XCTAssertLessThanOrEqual(long.targetKm, min(14, 17 * 0.8) + 0.001)
            }
        }
    }

    func test_sessions_buildWeek_hasThreeCoreSessionsPlusOneOptional() {
        let first = plannedWeeks().first!
        XCTAssertEqual(first.sessions.filter { !$0.isOptional }.map(\.kind),
                       [.longRun, .hills, .baseEndurance])
        XCTAssertEqual(first.sessions.filter(\.isOptional).count, 1)
    }

    func test_sessions_hillClimb_rampsToThreeQuartersOfRaceClimbAtPeak() {
        let weeks = plannedWeeks()
        let first = weeks.first!.sessions.first { $0.kind == .hills }!
        XCTAssertEqual(first.targetClimbM, 100, accuracy: 0.5)
        let peak = weeks.first { $0.role == .peak }!.sessions.first { $0.kind == .hills }!
        XCTAssertEqual(peak.targetClimbM, 300, accuracy: 0.5) // min(300, 400 × 0.75)
    }

    func test_sessions_raceWeek_swapsHillsForALegOpener() {
        let raceWeek = plannedWeeks().first { $0.role == .raceWeek }!
        XCTAssertFalse(raceWeek.sessions.contains { $0.kind == .hills })
        XCTAssertTrue(raceWeek.sessions.contains { $0.kind == .legOpener })
    }

    func test_sessions_taperWeeks_haveNoOptionalSession() {
        for week in plannedWeeks() where week.role == .taper || week.role == .raceWeek {
            XCTAssertFalse(week.sessions.contains(where: \.isOptional))
        }
    }

    func test_sessions_baseEndurance_isFlooredAtThreeKilometres() {
        let base = plannedWeeks().first!.sessions.first { $0.kind == .baseEndurance }!
        XCTAssertGreaterThanOrEqual(base.targetKm, 3.0 - 0.001)
    }

    func test_sessions_hrRanges_deriveFromHrMax() {
        let week = plannedWeeks().first!
        let hills = week.sessions.first { $0.kind == .hills }!
        XCTAssertEqual(hills.hrRange.lowerBound, 190 * 0.85, accuracy: 0.5)
        XCTAssertEqual(hills.hrRange.upperBound, 190 * 0.92, accuracy: 0.5)
        let long = week.sessions.first { $0.kind == .longRun }!
        XCTAssertEqual(long.hrRange.lowerBound, 190 * 0.70, accuracy: 0.5)
        XCTAssertEqual(long.hrRange.upperBound, 190 * 0.80, accuracy: 0.5)
    }
}
