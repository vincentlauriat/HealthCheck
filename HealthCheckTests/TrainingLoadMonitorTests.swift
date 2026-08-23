import XCTest
@testable import HealthCheck

final class TrainingLoadMonitorTests: XCTestCase {
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

    /// Historique réparti régulièrement sur 28 jours à raison de
    /// `perWeekKm` par semaine : coureur déjà entraîné.
    func weeklyHistory(perWeekKm: Double) -> [Workout] {
        (0..<28).map { run(dayString(from: "2026-08-23", offsetDays: -$0), km: perWeekKm / 7.0) }
    }

    // MARK: - Régime sans plan (ratio brut)

    func test_assess_comebackWithoutHistory_hasNoRatioAndSaysSo() {
        let a = TrainingLoadMonitor.assess(history: comebackHistory, plan: nil, readiness: nil,
                                           today: date("2026-08-23"), calendar: calendar)
        XCTAssertNil(a.acwr)
        XCTAssertTrue(a.alerts.contains { $0.severity == .info && $0.message.contains("Reprise en cours") })
        XCTAssertFalse(a.alerts.contains { $0.severity == .warning })
    }

    func test_assess_establishedHistory_exposesTheRatio() {
        let a = TrainingLoadMonitor.assess(history: weeklyHistory(perWeekKm: 10), plan: nil, readiness: nil,
                                           today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(a.acwr ?? -1, 1.0, accuracy: 0.05)
    }

    func test_assess_noPlan_highRatioWarns() {
        let history = weeklyHistory(perWeekKm: 10) + [run("2026-08-23", km: 20.0)]
        let a = TrainingLoadMonitor.assess(history: history, plan: nil, readiness: nil,
                                           today: date("2026-08-23"), calendar: calendar)
        XCTAssertGreaterThan(a.acwr ?? 0, 1.3)
        XCTAssertTrue(a.alerts.contains { $0.severity == .warning && $0.message.contains("trop vite") })
    }

    func test_assess_noPlan_lowRatioSuggestsMore() {
        // Trois semaines courues, rien cette semaine.
        let history = (7..<28).map { run(dayString(from: "2026-08-23", offsetDays: -$0), km: 2.0) }
        let a = TrainingLoadMonitor.assess(history: history, plan: nil, readiness: nil,
                                           today: date("2026-08-23"), calendar: calendar)
        XCTAssertLessThan(a.acwr ?? 1, 0.8)
        XCTAssertTrue(a.alerts.contains { $0.severity == .info && $0.message.contains("un peu plus") })
    }

    // MARK: - Régime avec plan actif (relatif à la cible)

    func test_assess_withPlan_rampWithinPlanDoesNotWarnDespiteHighRatio() {
        let g = goal()  // Paris-Versailles, 17 km, 400 m, 2026-09-27
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let target = plan.weeks.first { $0.role != .currentWeekClosing }!.targetKm
        // Semaine conforme au plan : on court exactement la cible.
        let onPlan = [run("2026-08-25", km: target * 0.55), run("2026-08-27", km: target * 0.45)]
        let a = TrainingLoadMonitor.assess(history: comeback + onPlan, plan: plan, readiness: nil,
                                           today: date("2026-08-28"), calendar: calendar)
        // Le ratio brut est énorme (reprise), mais rien ne doit alerter :
        // la montée respecte le plan, qui plafonne déjà la progression.
        XCTAssertFalse(a.alerts.contains { $0.severity == .warning },
                       "une montée conforme au plan ne doit jamais déclencher d'avertissement")
    }

    func test_assess_withPlan_exceedingTargetByMoreThanAQuarterWarns() {
        let g = goal()
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let target = plan.weeks.first { $0.role != .currentWeekClosing }!.targetKm
        // 1,4 × la cible : dépasse le seuil de +25 %.
        let overPlan = [run("2026-08-25", km: target * 0.8), run("2026-08-27", km: target * 0.6)]
        let a = TrainingLoadMonitor.assess(history: comeback + overPlan, plan: plan, readiness: nil,
                                           today: date("2026-08-28"), calendar: calendar)
        XCTAssertTrue(a.alerts.contains { $0.severity == .warning && $0.message.contains("dépassez le plan") })
    }

    func test_assess_withPlan_farBehindLateInTheWeek_informsWithoutWarning() {
        let g = goal()
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let target = plan.weeks.first { $0.role != .currentWeekClosing }!.targetKm
        let farBehind = [run("2026-08-25", km: target * 0.2)]
        // 2026-08-29 est un samedi : il ne reste que deux jours à la semaine.
        let a = TrainingLoadMonitor.assess(history: comeback + farBehind, plan: plan, readiness: nil,
                                           today: date("2026-08-29"), calendar: calendar)
        let alert = a.alerts.first { $0.message.contains("en retard") }
        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.severity, .info)
        XCTAssertFalse(a.alerts.contains { $0.severity == .warning })
    }

    // MARK: - Forme du jour

    func test_assess_lowReadiness_suggestsSwappingAHardDay() {
        let g = goal()
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let readiness = ReadinessScore(value: 42, label: "Fatigue", components: [])
        // Mardi, rien couru cette semaine : la sortie longue n'est pas faite.
        let a = TrainingLoadMonitor.assess(history: comeback, plan: plan, readiness: readiness,
                                           today: date("2026-08-25"), calendar: calendar)
        XCTAssertTrue(a.alerts.contains { $0.severity == .info && $0.message.contains("Forme du jour basse") })
    }

    func test_assess_goodReadiness_makesNoDaySuggestion() {
        let g = goal()
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let readiness = ReadinessScore(value: 73, label: "Bonne forme", components: [])
        let a = TrainingLoadMonitor.assess(history: comeback, plan: plan, readiness: readiness,
                                           today: date("2026-08-25"), calendar: calendar)
        XCTAssertFalse(a.alerts.contains { $0.message.contains("Forme du jour basse") })
    }

    func test_assess_lowReadinessButHardSessionsDone_makesNoSuggestion() {
        let g = goal()
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let week = plan.weeks.first { $0.role != .currentWeekClosing }!
        let longTarget = week.sessions.first { $0.kind == .longRun }!.targetKm
        let hillsTarget = week.sessions.first { $0.kind == .hills }!.targetKm
        let done = [run("2026-08-25", km: longTarget), run("2026-08-26", km: hillsTarget)]
        let readiness = ReadinessScore(value: 42, label: "Fatigue", components: [])
        let a = TrainingLoadMonitor.assess(history: comeback + done, plan: plan, readiness: readiness,
                                           today: date("2026-08-27"), calendar: calendar)
        XCTAssertFalse(a.alerts.contains { $0.message.contains("Forme du jour basse") })
    }
}
