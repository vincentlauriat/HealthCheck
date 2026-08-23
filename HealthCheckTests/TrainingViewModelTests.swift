import XCTest
@testable import HealthCheck

@MainActor
final class TrainingViewModelTests: XCTestCase {
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

    func hrRecord(_ day: String, value: Double) -> HealthRecord {
        HealthRecord(type: "HKQuantityTypeIdentifierHeartRate", sourceName: "Watch", device: nil,
                    unit: "count/min", value: value, startDate: date(day), endDate: date(day),
                    creationDate: date(day))
    }

    func goal(_ raceDay: String, km: Double = 17, climb: Double = 400) -> RaceGoal {
        RaceGoal(id: "g1", name: "Paris-Versailles", raceDate: date(raceDay, "10:00"),
                 distanceKm: km, elevationGainM: climb,
                 objective: .finishComfortable, createdAt: date("2026-08-01"))
    }

    // MARK: - État vide

    func test_load_withoutGoal_isEmptyStateAndHasLoaded() throws {
        let store = try HealthStore(path: ":memory:")
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertTrue(vm.hasLoaded)
        XCTAssertNil(vm.goal)
        XCTAssertNil(vm.plan)
        XCTAssertNil(vm.progress)
        // Pas d'objectif, mais le moniteur de charge tourne quand même —
        // il fonctionne comme un simple suivi entre deux courses.
        XCTAssertNotNil(vm.assessment)
        XCTAssertNil(vm.assessment?.acwr)
        XCTAssertEqual(vm.assessment?.acuteKm, 0)
        XCTAssertEqual(vm.assessment?.chronicWeeklyKm, 0)
        XCTAssertTrue(vm.assessment?.alerts.contains { $0.message.contains("Reprise en cours") } ?? false)
    }

    /// Carry-over de revue : sans objectif actif, `load` court-circuitait avant
    /// d'appeler `TrainingLoadMonitor.assess`, rendant la branche « sans plan »
    /// (alertes ACWR brutes) inatteignable depuis l'app bien que testée au
    /// niveau du moteur. Ce test pince cette branche via le view model.
    func test_load_withoutGoal_computesRawAcwrAssessment() throws {
        // Charge chronique = (5+5+5+20)/4 = 8.75 km/sem, juste au-dessus du
        // seuil meaningfulChronicKm (8.0) : c'est ce qui rend l'ACWR non-nil
        // ici sans dépendre du nombre de semaines actives. Un fixture plus
        // maigre ferait passer `meaningful` à faux et `acwr` à nil, faisant
        // échouer ce test sans pointer vers la bonne cause.
        let store = try HealthStore(path: ":memory:")
        try store.insertWorkouts([
            run("2026-07-29", km: 5.0),
            run("2026-08-05", km: 5.0),
            run("2026-08-12", km: 5.0),
            run("2026-08-20", km: 20.0)
        ])
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertNil(vm.goal)
        XCTAssertNil(vm.plan)
        XCTAssertNotNil(vm.assessment?.acwr)
        XCTAssertTrue(vm.assessment?.alerts.contains { $0.message.contains("progressez trop vite") } ?? false)
    }

    /// Carry-over de revue : aucun test existant ne distinguait la fenêtre
    /// d'historique de 90 jours d'une fenêtre plus courte, puisque toutes les
    /// séances des fixtures tombent à quelques jours d'aujourd'hui. Ce test
    /// place une séance à J-25 — dans la fenêtre chronique de 28 jours que
    /// lisent `TrainingPlanner`/`TrainingLoadMonitor`, mais hors d'une
    /// fenêtre d'historique trop courte pour la couvrir — et vérifie qu'elle
    /// change bien le plan. (Aucune séance plus ancienne que 28 jours n'a
    /// d'effet observable : ni le planificateur ni le moniteur ne lisent
    /// au-delà de cette fenêtre glissante ; les 90 jours de marge du view
    /// model garantissent seulement de couvrir ces 28 jours, pas davantage.)
    func test_load_historyWindow_coversTheTwentyEightDayChronicWindow() throws {
        let today = date("2026-08-24") // lundi : la semaine en cours reçoit des cibles
        let g = goal("2026-09-27")

        let storeWith = try HealthStore(path: ":memory:")
        try storeWith.saveRaceGoal(g)
        try storeWith.insertWorkouts([run("2026-07-30", km: 40.0), run("2026-08-19", km: 3.0)])
        let vmWith = TrainingViewModel(store: storeWith, calendar: calendar, now: { today })
        try vmWith.load()

        let storeWithout = try HealthStore(path: ":memory:")
        try storeWithout.saveRaceGoal(g)
        try storeWithout.insertWorkouts([run("2026-08-19", km: 3.0)])
        let vmWithout = TrainingViewModel(store: storeWithout, calendar: calendar, now: { today })
        try vmWithout.load()

        XCTAssertNotEqual(vmWith.plan, vmWithout.plan)
    }

    func test_load_pastGoalOnly_isEmptyState() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveRaceGoal(goal("2026-08-01"))
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertNil(vm.goal)
        XCTAssertNil(vm.plan)
    }

    // MARK: - Création d'objectif

    func test_createGoal_thenLoad_producesAPlan() throws {
        let store = try HealthStore(path: ":memory:")
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.createGoal(name: "Paris-Versailles", raceDate: date("2026-09-27", "10:00"),
                          distanceKm: 17, elevationGainM: 400)
        try vm.load()

        XCTAssertEqual(vm.goal?.name, "Paris-Versailles")
        XCTAssertFalse(vm.plan?.weeks.isEmpty ?? true)
    }

    func test_deleteActiveGoal_returnsToTheEmptyState() throws {
        let store = try HealthStore(path: ":memory:")
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })
        try vm.createGoal(name: "Paris-Versailles", raceDate: date("2026-09-27", "10:00"),
                          distanceKm: 17, elevationGainM: 400)
        try vm.load()
        XCTAssertNotNil(vm.goal)

        try vm.deleteActiveGoal()
        try vm.load()

        XCTAssertNil(vm.goal)
        XCTAssertNil(vm.plan)
    }

    // MARK: - Composition, pas ré-implémentation

    func test_load_planMatchesEngineOutputForTheSameInputs() throws {
        let store = try HealthStore(path: ":memory:")
        let g = goal("2026-09-27")
        try store.saveRaceGoal(g)
        try store.insertWorkouts([run("2026-08-18", km: 5.0), run("2026-08-20", km: 6.0)])
        let today = date("2026-08-23")
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { today })

        try vm.load()

        let historyStart = calendar.date(byAdding: .day, value: -90, to: today)!
        let storedHistory = try store.workouts(from: historyStart, to: today)
        let hrMaxCutoff = calendar.date(byAdding: .day, value: -180, to: today)!
        let hrMax = (try? store.maxValue(type: "HKQuantityTypeIdentifierHeartRate", from: hrMaxCutoff, to: today))
            .flatMap { $0 } ?? 190
        let expected = TrainingPlanner.plan(goal: g, history: storedHistory, hrMax: hrMax,
                                            today: today, calendar: calendar)

        XCTAssertEqual(vm.plan, expected)
    }

    // MARK: - Progression réelle

    func test_load_progressReflectsExecutedRuns() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveRaceGoal(goal("2026-09-27"))
        // Vendredi : 3 jours restants, la semaine en cours reçoit des cibles.
        try store.insertWorkouts([run("2026-08-19", km: 15.0)])
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-21") })

        try vm.load()

        let longRunMatch = vm.progress?.matched.first { $0.session.kind == .longRun }
        XCTAssertEqual(longRunMatch?.isDone, true)
        XCTAssertEqual(longRunMatch?.executed?.totalDistance, 15.0)
    }

    // MARK: - FC max

    func test_load_hrMax_usesTheIndexedAggregateWithinTheHundredEightyDayWindow() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveRaceGoal(goal("2026-09-27"))
        let today = date("2026-08-23")
        try store.insertRecords([
            hrRecord("2026-08-01", value: 201),   // dans la fenêtre de 180 jours
            hrRecord("2026-01-01", value: 250)    // hors fenêtre : doit être ignoré
        ])
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { today })

        try vm.load()

        XCTAssertEqual(vm.plan?.hrMax, 201)
    }

    // MARK: - Forme du jour

    func test_load_lowReadiness_producesTheDaySuggestion() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveRaceGoal(goal("2026-09-27"))
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-21") })

        try vm.load(readiness: ReadinessScore(value: 42, label: "Fatigue", components: []))

        XCTAssertTrue(vm.assessment?.alerts.contains { $0.message.contains("Forme du jour basse") } ?? false)
    }
}
