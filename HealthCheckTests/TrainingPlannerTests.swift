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

    func goal(_ raceDay: String = "2026-09-27", km: Double = 17, climb: Double = 400,
              createdAt: String = "2026-08-23") -> RaceGoal {
        RaceGoal(id: "g1", name: "Paris-Versailles", raceDate: date(raceDay, "10:00"),
                 distanceKm: km, elevationGainM: climb,
                 objective: .finishComfortable, createdAt: date(createdAt))
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

    /// Sans distance mesurée et sans durée exploitable (unité non
    /// reconnue), la séance ne doit fabriquer aucun kilomètre — 0, pas une
    /// estimation à partir d'une unité devinée.
    func test_distanceKm_withoutDistanceAndUnusableDuration_contributesZero() {
        let unusable = Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                               duration: 35, durationUnit: "furlong",
                               totalDistance: nil, totalDistanceUnit: nil,
                               totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                               startDate: date("2026-06-13"), endDate: date("2026-06-13"),
                               routeFileName: nil)
        XCTAssertEqual(TrainingPlanner.distanceKm(unusable), 0, accuracy: 0.001)
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
        // La règle s'évalue sur `createdAt`, donc l'objectif est créé ce
        // jour-là — c'est la semaine de création qui décide, pas `today`.
        let plan = TrainingPlanner.plan(goal: goal(createdAt: "2026-08-21"),
                                        history: comebackHistory, hrMax: 190,
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

    // MARK: - Ancrage à la création (spec §5.2bis)

    /// **C1 — la cible ne bouge pas pendant la semaine.** Le plan est
    /// reconstruit chaque jour de la semaine avec les sorties déjà courues
    /// ajoutées à l'historique, exactement comme le fait l'app à chaque
    /// affichage. Avant l'ancrage, la cible de la semaine en cours courait
    /// après le réalisé : 14,49 le dimanche, puis 22,77 / 18,05 / 24,55 /
    /// 25,50 les jours suivants — le plan bougeait sans action utilisateur.
    func test_plan_currentWeekTarget_doesNotMoveAsTheWeekIsRun() {
        let g = goal()  // créé dimanche 2026-08-23 → première semaine le 08-24
        let executed = [run("2026-08-24", km: 8.1), run("2026-08-26", km: 3.6),
                        run("2026-08-28", km: 2.8)]
        let firstMonday = calendar.startOfDay(for: date("2026-08-24"))

        for offset in 0...6 {
            let day = dayString(from: "2026-08-24", offsetDays: offset)
            let evening = date(day, "21:00")
            let history = comebackHistory + executed.filter { $0.startDate <= evening }
            let plan = TrainingPlanner.plan(goal: g, history: history, hrMax: 190,
                                            today: evening, calendar: calendar)
            let week = plan.weeks.first { $0.monday == firstMonday }
            XCTAssertNotNil(week, "la semaine du 08-24 doit rester dans le plan le \(day)")
            XCTAssertEqual(week?.targetKm ?? -1, 14.49, accuracy: 0.05,
                           "la cible de la semaine en cours a bougé le \(day)")
        }
    }

    /// **C3 — l'affûtage survit.** Deux semaines avant la course, un plan
    /// créé des semaines plus tôt doit toujours porter un rôle `.peak` et
    /// une semaine de course à ~9,58 km. Avant l'ancrage, `mondays` se
    /// recalculait depuis `today`, ne comptait plus que deux semaines, et
    /// la branche d'entretien produisait 14,4 km la semaine de la course —
    /// 51 % plus lourd.
    func test_plan_twoWeeksBeforeTheRace_stillTapersFromTheOriginalPeak() {
        let g = goal()  // créé 2026-08-23, course 2026-09-27
        // Le coureur a exécuté le plan : 14,49 puis 16,66 puis 19,16.
        let history = comebackHistory + [
            run("2026-08-26", km: 14.49), run("2026-09-02", km: 16.66), run("2026-09-09", km: 19.16)
        ]
        let plan = TrainingPlanner.plan(goal: g, history: history, hrMax: 190,
                                        today: date("2026-09-14"), calendar: calendar)

        XCTAssertFalse(plan.isMaintenance)
        XCTAssertEqual(plan.weeks.map(\.role), [.build, .build, .peak, .taper, .raceWeek])
        XCTAssertEqual(plan.weeks.first { $0.role == .peak }?.targetKm ?? 0, 19.16, accuracy: 0.05)
        XCTAssertEqual(plan.weeks.last?.targetKm ?? 0, 9.58, accuracy: 0.05)
    }

    /// La chaîne dorée doit sortir du **repliage** (semaines mesurées), pas
    /// seulement de la projection : pour un coureur qui exécute le plan à la
    /// lettre, les trois premières cibles restent 14,49 / 16,66 / 19,16 —
    /// la semaine 2 valant `min(14,49 ; 14,49) × 1,15`. Si le repliage ne
    /// reproduit pas ces nombres, le plafond est mal implémenté.
    func test_plan_foldReproducesTheGoldenChainForARunnerOnPlan() {
        let g = goal()
        let history = comebackHistory + [run("2026-08-26", km: 14.49), run("2026-09-02", km: 16.66)]
        let plan = TrainingPlanner.plan(goal: g, history: history, hrMax: 190,
                                        today: date("2026-09-07"), calendar: calendar)
        // `zip` tronque en silence : sans ce compte, un plan qui perdrait
        // ses semaines d'affûtage passerait sur les paires survivantes.
        XCTAssertEqual(plan.weeks.count, 5)
        for (got, want) in zip(plan.weeks.map(\.targetKm), [14.49, 16.66, 19.16, 14.37, 9.58]) {
            XCTAssertEqual(got, want, accuracy: 0.05)
        }
    }

    /// Les semaines à venir ne lisent aucune charge : sortir 30 km
    /// aujourd'hui ne doit rien changer à l'aperçu « Semaines suivantes ».
    func test_plan_futureWeeks_doNotMoveWhenTodaysLoadChanges() {
        let g = goal()
        let today = date("2026-08-25")  // mardi de la première semaine
        let quiet = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                         today: today, calendar: calendar)
        let busy = TrainingPlanner.plan(goal: g, history: comebackHistory + [run("2026-08-25", km: 30)],
                                        hrMax: 190, today: today, calendar: calendar)
        XCTAssertEqual(quiet.weeks.map(\.targetKm), busy.weeks.map(\.targetKm))
        XCTAssertEqual(quiet.weeks.map { w in w.sessions.first { $0.kind == .longRun }?.targetKm },
                       busy.weeks.map { w in w.sessions.first { $0.kind == .longRun }?.targetKm })
    }

    /// **Non-rattrapage, moitié haute.** Une semaine dépassée ne doit pas
    /// remonter la cible suivante : `base` est plafonné par `target_{i-1}`.
    /// Sans ce `min`, la charge mesurée (~30 km courus en semaine 1) ferait
    /// grimper la cible de la semaine 2 jusqu'au plafond (25,50 km) au lieu
    /// de rester bornée à 16,66 km.
    func test_plan_overshotWeek_doesNotRaiseTheNextTarget() {
        let g = goal()  // créé dimanche 2026-08-23 → semaine 1 le 08-24, semaine 2 le 08-31
        let history = comebackHistory + [run("2026-08-25", km: 30.0)]
        let plan = TrainingPlanner.plan(goal: g, history: history, hrMax: 190,
                                        today: date("2026-09-02"), calendar: calendar)
        let week2 = plan.weeks.first { $0.monday == calendar.startOfDay(for: date("2026-08-31")) }
        XCTAssertEqual(week2?.targetKm ?? -1, 16.66, accuracy: 0.05)
    }

    /// **Non-rattrapage, moitié basse.** Une semaine sautée doit re-baser la
    /// cible suivante vers le bas : `base` relit la charge mesurée plutôt
    /// que de recopier `target_{i-1}`. Si `base` restait simplement la
    /// cible précédente, la cible de la semaine 2 resterait à 16,66 km au
    /// lieu de retomber à 3,62 km.
    func test_plan_skippedWeek_rebasesTheNextTargetDown() {
        let g = goal()  // comebackHistory ne contient aucune sortie du 08-24 au 08-30
        let plan = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                        today: date("2026-09-02"), calendar: calendar)
        let week2 = plan.weeks.first { $0.monday == calendar.startOfDay(for: date("2026-08-31")) }
        XCTAssertEqual(week2?.targetKm ?? -1, 3.62, accuracy: 0.05)
    }

    /// La semaine de clôture n'appartient qu'à la semaine de création :
    /// passée celle-ci, il n'y a plus rien à clore.
    func test_plan_closingWeek_disappearsOnceTheCreationWeekIsOver() {
        let g = goal()  // créé dimanche 2026-08-23
        let during = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                          today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(during.weeks.first?.role, .currentWeekClosing)

        let after = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                         today: date("2026-08-24"), calendar: calendar)
        XCTAssertFalse(after.weeks.contains { $0.role == .currentWeekClosing })
        XCTAssertEqual(after.weeks.first?.monday, calendar.startOfDay(for: date("2026-08-24")))
    }

    /// **I2 — objectif créé le samedi qui précède sa propre course.**
    /// Décaler la première semaine de construction au lundi suivant
    /// sauterait la course et rendrait un plan vide ; on garde alors la
    /// semaine de création.
    func test_plan_goalCreatedTheSaturdayBeforeItsRace_stillProducesTheRaceWeek() {
        let g = goal("2026-09-27", createdAt: "2026-09-26")  // samedi, course le lendemain
        let plan = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                        today: date("2026-09-26"), calendar: calendar)

        XCTAssertFalse(plan.weeks.isEmpty, "un plan ne doit jamais être vide pour une course à venir")
        XCTAssertEqual(plan.weeks.map(\.role), [.raceWeek])
        XCTAssertTrue(plan.isMaintenance)
        XCTAssertTrue(plan.weeks[0].sessions.contains { $0.kind == .legOpener })
    }

    func test_firstBuildMonday_isReadFromCreationNotFromToday() {
        // Créé un dimanche : la rampe démarre le lundi suivant, et cette
        // réponse ne dépend d'aucune date « aujourd'hui ».
        XCTAssertEqual(TrainingPlanner.firstBuildMonday(goal: goal(), calendar: calendar),
                       calendar.startOfDay(for: date("2026-08-24")))
        // Créé un vendredi : trois jours restants, la semaine de création
        // reçoit les cibles.
        XCTAssertEqual(TrainingPlanner.firstBuildMonday(goal: goal(createdAt: "2026-08-21"),
                                                        calendar: calendar),
                       calendar.startOfDay(for: date("2026-08-17")))
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

    // MARK: - Pédagogie (rationale, ancrage exposé, plus longue sortie)

    /// Une sortie longue en semaine de pic et une en affûtage ne se
    /// justifient pas de la même façon — `rationale` doit distinguer les
    /// deux, avec le texte exact attendu par la vue.
    func test_sessions_longRun_rationaleDiffersBetweenPeakAndTaper() {
        let peak = TrainingPlanner.sessions(role: .peak, targetKm: 20, previousLongKm: 10,
                                            climbTargetM: 100, goal: goal(), hrMax: 190)
        let taper = TrainingPlanner.sessions(role: .taper, targetKm: 10, previousLongKm: 10,
                                             climbTargetM: 50, goal: goal(), hrMax: 190)
        let peakLong = peak.first { $0.kind == .longRun }!
        let taperLong = taper.first { $0.kind == .longRun }!
        XCTAssertNotEqual(peakLong.rationale, taperLong.rationale)
        XCTAssertEqual(peakLong.rationale,
            "Elle construit votre distance : plus de capillaires, plus de mitochondries, une meilleure utilisation des graisses comme carburant. C'est 60 % du volume de la semaine — la séance à ne jamais sacrifier.")
        XCTAssertEqual(taperLong.rationale,
            "Allégée volontairement. À ce stade, entretenir suffit : ce que vous gagnez maintenant, c'est de la fraîcheur, pas de la forme.")
    }

    /// Garde contre un genre de séance ajouté plus tard sans motif : chaque
    /// séance de chaque semaine d'un plan complet doit porter un
    /// `rationale` non vide. Le compte de séances vérifiées est asserté
    /// pour empêcher un test qui n'itérerait rien de passer à vide.
    func test_sessions_everySessionInEveryWeek_hasNonEmptyRationale() {
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        var checkedCount = 0
        for week in plan.weeks {
            for session in week.sessions {
                checkedCount += 1
                XCTAssertFalse(session.rationale.isEmpty,
                               "\(session.kind) dans la semaine du \(week.monday) a un rationale vide")
            }
        }
        // Le plan golden couvre build/build/peak/taper/raceWeek : s'assurer
        // qu'on a bien inspecté des séances réelles, pas une liste vide.
        XCTAssertGreaterThan(checkedCount, 10)
    }

    /// `anchorBaseKm`/`rampFactor` exposés sur `TrainingPlan` doivent
    /// refléter exactement la base mesurée à l'ancrage : ~12,6 km/semaine
    /// et le facteur de reprise pour un coureur qui reprend, 21 km/semaine
    /// et le facteur établi pour un coureur déjà entraîné.
    func test_plan_anchorBaseKmAndRampFactor_matchTheMeasuredBase() {
        let comebackPlan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                                 today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(comebackPlan.anchorBaseKm, 12.6, accuracy: 0.05)
        XCTAssertEqual(comebackPlan.rampFactor, TrainingPlanner.comebackRampFactor, accuracy: 0.001)

        let establishedPlan = TrainingPlanner.plan(goal: goal(), history: trainedHistory(), hrMax: 190,
                                                    today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(establishedPlan.anchorBaseKm, 21.0, accuracy: 0.05)
        XCTAssertEqual(establishedPlan.rampFactor, TrainingPlanner.steadyRampFactor, accuracy: 0.001)
    }

    /// `longestPlannedRunKm` doit être le maximum réel des sorties longues
    /// du plan, pas une valeur recalculée séparément — donc égal à la
    /// sortie longue de la semaine de pic sur la chaîne dorée.
    func test_longestPlannedRunKm_equalsThePeakWeeksLongRun() {
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        let peakLong = plan.weeks.first { $0.role == .peak }?.sessions.first { $0.kind == .longRun }?.targetKm
        XCTAssertNotNil(peakLong)
        XCTAssertEqual(plan.longestPlannedRunKm, peakLong!, accuracy: 0.001)
        XCTAssertEqual(plan.longestPlannedRunKm, 11.5, accuracy: 0.05)
    }

    /// Nombre de semaines de cibles (build/peak/taper/raceWeek) qu'un
    /// objectif produirait, recalculé indépendamment de `plan(...)` à
    /// partir des seules fonctions pures `firstBuildMonday`/`monday` — pour
    /// que le test ne duplique pas la logique de rôle qu'il vérifie.
    private func mondaysCount(goal g: RaceGoal) -> Int {
        let first = TrainingPlanner.firstBuildMonday(goal: g, calendar: calendar)
        let raceMonday = TrainingPlanner.monday(of: g.raceDate, calendar: calendar)
        var count = 0
        var cursor = first
        while cursor <= raceMonday {
            count += 1
            cursor = calendar.date(byAdding: .day, value: 7, to: cursor)!
        }
        return count
    }

    /// La chaîne dorée (5 semaines de cibles, rôles
    /// build/build/peak/taper/raceWeek) doit porter 3 semaines qui montent
    /// (build/build/peak) et 2 qui redescendent (taper/raceWeek) — la forme
    /// que l'explicateur de plan doit annoncer pour ce cas.
    func test_planArcCounts_fiveWeekGoal_matchesGoldenRoles() {
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(plan.rampWeekCount, 3)
        XCTAssertEqual(plan.taperWeekCount, 2)
    }

    /// Un objectif plus lointain porte plus de semaines de montée — la
    /// phrase d'arc ne peut donc pas être une constante figée à « trois »
    /// et « deux » : elle doit suivre la vraie longueur du plan.
    func test_planArcCounts_scaleWithPlanLength() {
        let longerGoal = goal("2026-12-06")
        let totalTargetWeeks = mondaysCount(goal: longerGoal)
        XCTAssertGreaterThan(totalTargetWeeks, 5,
                             "le fixture doit produire un plan plus long que la chaîne dorée à 5 semaines")

        let plan = TrainingPlanner.plan(goal: longerGoal, history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(plan.rampWeekCount, totalTargetWeeks - 2)
        XCTAssertEqual(plan.taperWeekCount, 2)

        let fiveWeekPlan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                                today: date("2026-08-23"), calendar: calendar)
        XCTAssertGreaterThan(plan.rampWeekCount, fiveWeekPlan.rampWeekCount,
                             "un plan plus long doit annoncer plus de semaines de montée, pas le même chiffre")
    }

    /// Un plan de maintien ne monte jamais : aucune semaine build/peak, et
    /// toutes les semaines de cibles sont taper/raceWeek. La phrase d'arc
    /// n'a alors aucun sens — c'est la branche `isMaintenance` de la vue
    /// qui doit l'éviter, mais le compte lui-même doit rester correct.
    func test_planArcCounts_maintenanceGoal_hasNoRampWeeks() {
        let g = goal("2026-09-27", createdAt: "2026-09-26")  // course le lendemain de la création
        let plan = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                        today: date("2026-09-26"), calendar: calendar)
        XCTAssertTrue(plan.isMaintenance)
        XCTAssertEqual(plan.rampWeekCount, 0)
        XCTAssertEqual(plan.taperWeekCount, 1)
    }
}
