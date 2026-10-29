import XCTest
@testable import HealthCheck

/// Saison de courses : une course principale, des courses de préparation
/// intégrées au plan, la périodisation 3 + 1 et les plafonds calés sur le
/// niveau et le profil de la course (spec 2026-10-29 season planning).
final class SeasonPlanningTests: XCTestCase {
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

    func run(_ day: String, km: Double) -> Workout {
        Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                duration: km * 7, durationUnit: "min",
                totalDistance: km, totalDistanceUnit: "km",
                totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                startDate: date(day), endDate: date(day).addingTimeInterval(km * 7 * 60),
                routeFileName: nil)
    }

    func race(_ id: String, _ name: String, on day: String, km: Double, climb: Double,
              priority: RaceGoal.Priority, createdAt: String = "2026-10-29",
              override: Double? = nil) -> RaceGoal {
        RaceGoal(id: id, name: name, raceDate: date(day, "10:00"), distanceKm: km,
                 elevationGainM: climb, objective: .finishComfortable, createdAt: date(createdAt),
                 priority: priority, peakWeeklyKmOverride: override)
    }

    // La saison réelle de Vincent, saisie le jeudi 2026-10-29.
    var chevreuse: RaceGoal {
        race("c", "Route des 4 Châteaux", on: "2026-11-15", km: 18, climb: 300, priority: .tuneUp)
    }
    var figaro: RaceGoal {
        race("f", "Cross du Figaro", on: "2026-11-29", km: 10, climb: 0, priority: .tuneUp)
    }
    var restonica: RaceGoal {
        race("r", "Restonica GT20K", on: "2027-07-09", km: 17, climb: 650, priority: .main)
    }

    /// Son historique Strava d'octobre : une reprise irrégulière.
    var octoberHistory: [Workout] {
        [run("2026-10-03", km: 0.71), run("2026-10-10", km: 4.80), run("2026-10-13", km: 7.03),
         run("2026-10-14", km: 8.38), run("2026-10-29", km: 3.70)]
    }

    func seasonPlan(today: String = "2026-10-29", history: [Workout]? = nil) -> TrainingPlan {
        TrainingPlanner.plan(goal: restonica, tuneUps: [chevreuse, figaro],
                             history: history ?? octoberHistory, hrMax: 185,
                             today: date(today), calendar: calendar)
    }

    func week(_ plan: TrainingPlan, _ monday: String) -> PlannedWeek {
        plan.weeks.first { $0.monday == calendar.startOfDay(for: date(monday)) }!
    }

    // MARK: - Modèle

    func test_effortKm_addsOneKilometrePerHundredMetresOfClimb() {
        XCTAssertEqual(restonica.effortKm, 23.5, accuracy: 0.001)
        XCTAssertEqual(figaro.effortKm, 10, accuracy: 0.001)
    }

    func test_isTrail_startsAtThirtyMetresOfClimbPerKilometre() {
        XCTAssertTrue(restonica.isTrail)                                         // 38 m/km
        XCTAssertFalse(chevreuse.isTrail)                                        // 17 m/km
        XCTAssertTrue(race("t", "T", on: "2027-01-01", km: 10, climb: 300, priority: .main).isTrail)
        XCTAssertFalse(race("t", "T", on: "2027-01-01", km: 10, climb: 299, priority: .main).isTrail)
    }

    func test_active_prefersTheMainRaceOverANearerTuneUp() {
        let active = RaceGoal.active(in: [chevreuse, figaro, restonica], today: date("2026-10-29"),
                                     calendar: calendar)
        XCTAssertEqual(active?.id, "r")
    }

    func test_active_withoutAnyMainRace_fallsBackToTheNearestRace() {
        let active = RaceGoal.active(in: [figaro, chevreuse], today: date("2026-10-29"),
                                     calendar: calendar)
        XCTAssertEqual(active?.id, "c")
    }

    /// Les courses de préparation **passées** restent dans le plan : sans
    /// elles, les semaines déjà courues seraient recalculées autrement le
    /// lendemain de chaque course.
    func test_tuneUps_keepPastOnes_andOnlyThoseBeforeTheMainRace() {
        let after = race("a", "Après", on: "2027-09-01", km: 10, climb: 0, priority: .tuneUp)
        let otherMain = race("m", "Autre", on: "2027-03-01", km: 21, climb: 0, priority: .main)
        let picked = RaceGoal.tuneUps(for: restonica, in: [after, figaro, restonica, chevreuse, otherMain])
        XCTAssertEqual(picked.map(\.id), ["c", "f"])
    }

    // MARK: - Courses de préparation

    func test_tuneUpWeek_replacesTheLongRunWithTheRace() {
        let w = week(seasonPlan(), "2026-11-09")
        XCTAssertEqual(w.role, .tuneUp)
        XCTAssertEqual(w.tuneUp?.id, "c")
        XCTAssertEqual(w.sessions.map(\.kind), [.tuneUpRace, .legOpener, .baseEndurance])
        let raceSession = w.sessions[0]
        XCTAssertEqual(raceSession.targetKm, 18, accuracy: 0.001)
        XCTAssertEqual(raceSession.targetClimbM, 300, accuracy: 0.001)
        XCTAssertTrue(raceSession.note.contains("Route des 4 Châteaux"))
        XCTAssertFalse(w.sessions.contains { $0.kind == .longRun })
    }

    /// 13,2 km de montée × 0,85 ferait 11,2 km : moins que la course
    /// elle-même. Le plancher « course + footing » doit l'emporter.
    func test_tuneUpWeek_targetAlwaysContainsTheRacePlusAnEasyRun() {
        let w = week(seasonPlan(), "2026-11-09")
        XCTAssertEqual(w.targetKm, 18 + TrainingPlanner.minimumBaseKm, accuracy: 0.001)
    }

    func test_longTuneUp_isFollowedByARecoveryWeek() {
        let plan = seasonPlan()
        let after = week(plan, "2026-11-16")
        XCTAssertEqual(after.role, .recovery)
        // 0,7 × la dernière cible de montée (semaine du 2 novembre).
        XCTAssertEqual(after.targetKm, week(plan, "2026-11-02").targetKm * 0.7, accuracy: 0.001)
        XCTAssertFalse(after.sessions.contains { $0.kind == .hills || $0.kind == .vo2MaxIntervals })
    }

    /// Un 10 km plat (10 km-effort) ne justifie pas une semaine allégée :
    /// la montée reprend dès le lundi suivant.
    func test_shortTuneUp_isNotFollowedByARecoveryWeek() {
        let plan = seasonPlan()
        XCTAssertEqual(week(plan, "2026-11-23").role, .tuneUp)
        XCTAssertEqual(week(plan, "2026-11-30").role, .build)
    }

    /// Ni la course ni la récupération ne font perdre la progression : la
    /// première semaine de montée qui suit repart de la dernière cible de
    /// montée (2 novembre), pas du creux.
    func test_ramp_resumesFromTheLastBuildTarget_afterRacesAndRecovery() {
        let plan = seasonPlan()
        let lastBuild = week(plan, "2026-11-02").targetKm
        XCTAssertEqual(week(plan, "2026-11-30").targetKm, lastBuild * plan.rampFactor, accuracy: 0.001)
    }

    /// Une course qui tombe pendant l'affûtage garde le rôle de la semaine
    /// et prend seulement la place de la sortie longue.
    func test_tuneUpDuringTaper_keepsTheRoleAndReplacesTheLongRun() {
        let late = race("l", "10 km de juin", on: "2027-07-02", km: 10, climb: 0, priority: .tuneUp)
        let plan = TrainingPlanner.plan(goal: restonica, tuneUps: [late], history: octoberHistory,
                                        hrMax: 185, today: date("2026-10-29"), calendar: calendar)
        let w = week(plan, "2027-06-28")
        XCTAssertEqual(w.role, .taper)
        XCTAssertEqual(w.tuneUp?.id, "l")
        XCTAssertTrue(w.sessions.contains { $0.kind == .tuneUpRace })
        XCTAssertFalse(w.sessions.contains { $0.kind == .longRun })
    }

    /// La sortie longue d'une semaine allégée est raccourcie, mais ne sert
    /// pas de graine à la suivante : la progression repart de la dernière
    /// vraie sortie longue (2 novembre), sinon chaque récupération ferait
    /// reculer la distance de plusieurs semaines.
    func test_longRunProgression_skipsRecoveryAndRaceWeeks() {
        let plan = seasonPlan()
        func long(_ monday: String) -> Double {
            week(plan, monday).sessions.first { $0.kind == .longRun }!.targetKm
        }
        let resumed = week(plan, "2026-11-30")
        XCTAssertEqual(long("2026-11-30"),
                       min(resumed.targetKm * TrainingPlanner.longRunShare,
                           long("2026-11-02") + TrainingPlanner.longRunWeeklyGrowthKm),
                       accuracy: 0.001)
        XCTAssertLessThan(long("2026-11-16"), long("2026-11-02"), "la semaine allégée raccourcit la sortie longue")
    }

    // MARK: - Périodisation

    func test_longPlan_insertsARecoveryWeekAfterEveryThreeBuildWeeks() {
        let plan = TrainingPlanner.plan(goal: restonica, history: octoberHistory, hrMax: 185,
                                        today: date("2026-10-29"), calendar: calendar)
        var streak = 0
        for w in plan.weeks {
            switch w.role {
            case .build: streak += 1
            case .recovery:
                XCTAssertEqual(streak, TrainingPlanner.buildWeeksPerCycle,
                               "une semaine allégée vient après exactement trois semaines de montée")
                streak = 0
            default: break
            }
            XCTAssertLessThanOrEqual(streak, TrainingPlanner.buildWeeksPerCycle + 1)
        }
        XCTAssertGreaterThan(plan.recoveryWeekCount, 5)
    }

    /// On arrive au pic sur une montée : ni le pic ni la semaine qui le
    /// précède ne sont allégés.
    func test_recovery_isNeverThePeakNorTheWeekBeforeIt() {
        let plan = seasonPlan()
        let peakIndex = plan.weeks.firstIndex { $0.role == .peak }!
        XCTAssertNotEqual(plan.weeks[peakIndex - 1].role, .recovery)
        XCTAssertEqual(plan.weeks.filter { $0.role == .peak }.count, 1)
    }

    /// Fixture choisi pour que le cycle tombe **exactement** sur la semaine
    /// d'avant le pic : 11 semaines, pic à l'index 8, cycle 3 + 1 qui
    /// voudrait alléger l'index 7. La semaine doit rester une montée.
    func test_cycleLandingOnTheWeekBeforeThePeak_staysABuildWeek() {
        let winter = race("w", "Trail d'hiver", on: "2027-01-16", km: 17, climb: 650,
                          priority: .main, createdAt: "2026-11-02")
        let plan = TrainingPlanner.plan(goal: winter, history: octoberHistory, hrMax: 185,
                                        today: date("2026-11-02"), calendar: calendar)
        XCTAssertEqual(plan.weeks.count, 11)
        let peakIndex = plan.weeks.firstIndex { $0.role == .peak }!
        XCTAssertEqual(peakIndex, 8)
        XCTAssertEqual(plan.weeks[3].role, .recovery)
        XCTAssertEqual(plan.weeks[4..<7].map(\.role), [.build, .build, .build],
                       "trois montées d'affilée : le cycle réclamerait un allègement à l'index 7")
        XCTAssertEqual(plan.weeks[7].role, .build)
    }

    /// Une semaine allégée n'est pas un effondrement : elle baisse par
    /// construction et ne doit pas déclencher l'alerte « plan en repli ».
    func test_hasCollapsed_ignoresRecoveryAndTuneUpWeeks() {
        let build = PlannedWeek(monday: date("2026-12-14"), role: .build, targetKm: 20, sessions: [])
        let recovery = PlannedWeek(monday: date("2026-12-21"), role: .recovery, targetKm: 5, sessions: [])
        let tuneUp = PlannedWeek(monday: date("2026-12-21"), role: .tuneUp, targetKm: 5, sessions: [])
        XCTAssertFalse(TrainingLoadMonitor.hasCollapsed(current: recovery, previous: build))
        XCTAssertFalse(TrainingLoadMonitor.hasCollapsed(current: tuneUp, previous: build))
    }

    // MARK: - Plafonds calés sur la course et le niveau

    func test_volumeCap_followsRaceEffortKm() {
        let plan = seasonPlan()
        XCTAssertEqual(plan.volumeCapKm, 23.5 * 1.5, accuracy: 0.001)
        XCTAssertEqual(week(plan, "2027-06-21").role, .peak)
        XCTAssertEqual(week(plan, "2027-06-21").targetKm, 23.5 * 1.5, accuracy: 0.001)
    }

    /// Un coureur qui court déjà plus que le plafond calculé n'est pas
    /// ramené en dessous : le plafond ne descend jamais sous sa base.
    func test_volumeCap_neverDropsBelowTheMeasuredBase() {
        let tenK = race("t", "10 km", on: "2027-03-01", km: 10, climb: 0, priority: .main)
        XCTAssertEqual(TrainingPlanner.volumeCapKm(goal: tenK, anchorBaseKm: 40), 40, accuracy: 0.001)
        XCTAssertEqual(TrainingPlanner.volumeCapKm(goal: tenK, anchorBaseKm: 10), 15, accuracy: 0.001)
    }

    /// « Rien n'est interdit » : un plafond choisi est appliqué tel quel,
    /// même deux fois au-dessus du calcul.
    func test_override_isAppliedAsIs_evenFarAboveTheComputedCap() {
        let bold = race("r", "Restonica GT20K", on: "2027-07-09", km: 17, climb: 650,
                        priority: .main, override: 70)
        let plan = TrainingPlanner.plan(goal: bold, history: octoberHistory, hrMax: 185,
                                        today: date("2026-10-29"), calendar: calendar)
        XCTAssertEqual(plan.volumeCapKm, 70, accuracy: 0.001)
        XCTAssertTrue(plan.isVolumeCapOverridden)
        XCTAssertGreaterThan(plan.weeks.first { $0.role == .peak }!.targetKm, 23.5 * 1.5)
    }

    func test_longRun_reachesTheRaceDistanceOnALongPlan() {
        XCTAssertEqual(seasonPlan().longestPlannedRunKm, 17, accuracy: 0.001)
    }

    /// Plus de plafond de 300 m : au pic, la séance de côtes vise 75 % du
    /// D+ de la course, soit 487,5 m pour 650 m.
    func test_hillsAtPeak_followTheRaceClimbWithoutTheOld300mCeiling() {
        let peak = seasonPlan().weeks.first { $0.role == .peak }!
        let hills = peak.sessions.first { $0.kind == .hills }!
        XCTAssertEqual(hills.targetClimbM, 487.5, accuracy: 0.01)
    }

    /// Sur un trail, la sortie longue porte le gradient de la course.
    func test_trailLongRun_carriesTheRaceGradient() {
        let peak = seasonPlan().weeks.first { $0.role == .peak }!
        let long = peak.sessions.first { $0.kind == .longRun }!
        XCTAssertEqual(long.targetClimbM, long.targetKm * 650 / 17, accuracy: 0.01)
        XCTAssertTrue(long.note.contains("D+"))
    }

    func test_roadLongRun_carriesNoClimb() {
        let road = race("p", "Semi", on: "2027-03-01", km: 21.1, climb: 50, priority: .main)
        let plan = TrainingPlanner.plan(goal: road, history: octoberHistory, hrMax: 185,
                                        today: date("2026-10-29"), calendar: calendar)
        for w in plan.weeks {
            if let long = w.sessions.first(where: { $0.kind == .longRun }) {
                XCTAssertEqual(long.targetClimbM, 0)
            }
        }
    }

    // MARK: - Déterminisme

    /// Le lendemain de Chevreuse, les semaines passées et l'aperçu ne
    /// bougent pas pour autant (la course compte, le rôle est ancré).
    func test_seasonPlan_pastTuneUpWeekIsStableAfterTheRace() {
        let before = seasonPlan(today: "2026-11-14")
        let afterRace = seasonPlan(today: "2026-11-16",
                                   history: octoberHistory + [run("2026-11-15", km: 18)])
        XCTAssertEqual(week(before, "2026-11-09").role, week(afterRace, "2026-11-09").role)
        XCTAssertEqual(week(before, "2026-11-09").targetKm, week(afterRace, "2026-11-09").targetKm,
                       accuracy: 0.001)
        XCTAssertEqual(week(afterRace, "2026-11-16").role, .recovery)
    }

    // MARK: - Moniteur de charge

    func test_assess_recoveryWeek_isAnnouncedAsIntended() {
        let plan = seasonPlan(today: "2026-11-18")
        let a = TrainingLoadMonitor.assess(history: octoberHistory, plan: plan, readiness: nil,
                                           today: date("2026-11-18"), calendar: calendar)
        XCTAssertTrue(a.alerts.contains { $0.message.contains("Semaine allégée") })
    }

    func test_assess_highOverride_isMentionedNeverRefused() {
        let bold = race("r", "Restonica GT20K", on: "2027-07-09", km: 17, climb: 650,
                        priority: .main, override: 70)
        let plan = TrainingPlanner.plan(goal: bold, history: octoberHistory, hrMax: 185,
                                        today: date("2026-10-29"), calendar: calendar)
        let a = TrainingLoadMonitor.assess(history: octoberHistory, plan: plan, readiness: nil,
                                           today: date("2026-10-29"), calendar: calendar)
        let alert = a.alerts.first { $0.message.contains("Plafond personnalisé") }
        XCTAssertEqual(alert?.severity, .info)
        XCTAssertEqual(plan.volumeCapKm, 70, accuracy: 0.001)
    }

    /// 40 km pour un calcul à 35,25 : dans la marge de 1,3, rien à dire.
    func test_assess_modestOverride_isSilent() {
        let modest = race("r", "Restonica GT20K", on: "2027-07-09", km: 17, climb: 650,
                          priority: .main, override: 40)
        let plan = TrainingPlanner.plan(goal: modest, history: octoberHistory, hrMax: 185,
                                        today: date("2026-10-29"), calendar: calendar)
        let a = TrainingLoadMonitor.assess(history: octoberHistory, plan: plan, readiness: nil,
                                           today: date("2026-10-29"), calendar: calendar)
        XCTAssertFalse(a.alerts.contains { $0.message.contains("Plafond personnalisé") })
    }
}
