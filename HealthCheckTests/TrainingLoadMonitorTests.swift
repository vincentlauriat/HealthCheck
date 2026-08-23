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

    /// Fixture round 1 (post-review) : la version originale ne pinnait rien,
    /// car son historique (une seule semaine de reprise) fermait la porte de
    /// signifiance (`weeksWithARun == 2`, `chronic == 6.77 < 8`) — `acwr`
    /// valait donc `nil`, et le ratio brut de 3,26 n'était jamais atteignable.
    /// Supprimer la branche du plan ne changeait alors rien : le test passait
    /// pour de mauvaises raisons.
    ///
    /// Ici les trois conditions tiennent en même temps à la date d'évaluation
    /// (2026-08-28) :
    /// - la porte de signifiance est ouverte : 4 semaines sur 4 (03, 10, 17,
    ///   24 août) contiennent une sortie → `acwr` n'est pas `nil` ;
    /// - le ratio brut est réellement élevé : aigu = 10 km (les deux sorties
    ///   de la semaine en cours), chronique = (5+5+5+10)/4 = 6,25 →
    ///   ratio = 10 / 6,25 = 1,6, bien au-dessus du seuil de 1,3 ;
    /// - le volume exécuté cette semaine (10 km) reste sous 125 % de la
    ///   cible du plan (≈ 11,5 km × 1,25 = 14,375 km), donc la branche
    ///   relative au plan n'a elle-même aucune raison d'alerter.
    func test_assess_withPlan_rampWithinPlanDoesNotWarnDespiteHighRatio() {
        let g = goal()  // Paris-Versailles, 17 km, 400 m, 2026-09-27
        // Trois semaines régulières avant la semaine en cours.
        let baseline = [run("2026-08-03", km: 5.0), run("2026-08-10", km: 5.0), run("2026-08-17", km: 5.0)]
        let plan = TrainingPlanner.plan(goal: g, history: baseline, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        let target = plan.weeks.first { $0.role != .currentWeekClosing }!.targetKm
        // Semaine conforme au plan : 10 km, sous la cible × 1,25.
        let onPlan = [run("2026-08-25", km: 6.0), run("2026-08-27", km: 4.0)]
        let a = TrainingLoadMonitor.assess(history: baseline + onPlan, plan: plan, readiness: nil,
                                           today: date("2026-08-28"), calendar: calendar)
        // Le ratio brut (1,6) dépasse le seuil (1,3), mais rien ne doit
        // alerter : la montée respecte le plan, qui plafonne déjà la
        // progression.
        XCTAssertNotNil(a.acwr)
        XCTAssertGreaterThan(a.acwr ?? 0, 1.3)
        XCTAssertLessThanOrEqual(onPlan.reduce(0) { $0 + ($1.totalDistance ?? 0) }, target * 1.25)
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

    // MARK: - Garde-fous du branchement plan (fix round 1)

    /// La semaine en cours peut être `.currentWeekClosing` (cible à 0, trop
    /// tard pour recevoir des consignes). Sans le garde `week.role !=
    /// .currentWeekClosing`, n'importe quelle sortie dépasserait
    /// mécaniquement `0 × 1,25`, et un avertissement « dépassez le plan »
    /// se déclencherait à tort.
    func test_assess_withPlan_currentWeekClosing_producesNoOvershootWarning() {
        let g = goal()
        // 2026-08-23 est un dimanche : il ne reste qu'un jour à la semaine
        // du 08-17, qui devient donc `.currentWeekClosing` (cible à 0).
        let plan = TrainingPlanner.plan(goal: g, history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(plan.weeks.first?.role, .currentWeekClosing)
        XCTAssertEqual(plan.weeks.first?.targetKm, 0)
        let a = TrainingLoadMonitor.assess(history: comebackHistory, plan: plan, readiness: nil,
                                           today: date("2026-08-23"), calendar: calendar)
        XCTAssertFalse(a.alerts.contains { $0.severity == .warning })
    }

    /// Round 2 : réécrit après le correctif `plan == nil`. Quand `today` ne
    /// correspond à aucune semaine du plan, le comportement n'est PLUS
    /// « identique à l'absence de plan » — c'est justement la confusion que
    /// le correctif supprime. Seule l'absence réelle d'un objectif ouvre la
    /// porte au ratio brut ; un plan présent la ferme, même sans semaine
    /// correspondant à aujourd'hui, et se contente d'exposer `acwr` pour
    /// l'affichage.
    func test_assess_todayOutsideEveryPlanWeek_onlyTheNoPlanCaseWarns() {
        let g = goal()  // course le 2026-09-27
        let comeback = [run("2026-08-18", km: 5.0), run("2026-08-22", km: 2.0), run("2026-08-23", km: 5.6)]
        let plan = TrainingPlanner.plan(goal: g, history: comeback, hrMax: 190,
                                        today: date("2026-08-24"), calendar: calendar)
        // La dernière semaine du plan commence le 2026-09-21 (semaine de
        // course) ; le 2026-10-15 n'appartient à aucune semaine du plan.
        XCTAssertFalse(plan.weeks.contains { $0.monday == TrainingPlanner.monday(of: date("2026-10-15"), calendar: calendar) })
        let laterHistory = (0..<28).map { run(dayString(from: "2026-10-15", offsetDays: -$0), km: 10.0 / 7.0) }
            + [run("2026-10-15", km: 20.0)]
        // Sans plan : le ratio brut élevé déclenche l'avertissement — inchangé.
        let withoutPlan = TrainingLoadMonitor.assess(history: laterHistory, plan: nil, readiness: nil,
                                                      today: date("2026-10-15"), calendar: calendar)
        XCTAssertTrue(withoutPlan.alerts.contains { $0.severity == .warning && $0.message.contains("trop vite") })
        // Avec un plan présent — même sans semaine correspondant à
        // aujourd'hui — aucune alerte : la présence d'un objectif ferme la
        // porte au ratio brut. Le ratio reste exposé pour l'affichage.
        let withPlan = TrainingLoadMonitor.assess(history: laterHistory, plan: plan, readiness: nil,
                                                   today: date("2026-10-15"), calendar: calendar)
        XCTAssertEqual(withPlan.acwr, withoutPlan.acwr)
        XCTAssertTrue(withPlan.alerts.isEmpty)
    }

    /// Round 2 (Critique) : le repli sur le ratio brut ne doit se déclencher
    /// qu'en l'absence totale de plan — pas simplement quand la semaine en
    /// cours n'a pas de cible. Une semaine `.currentWeekClosing` survient
    /// chaque samedi et dimanche dès qu'un plan est actif (moins de 3 jours
    /// restants) ; avant ce correctif, le ratio brut y déclenchait
    /// l'avertissement « trop vite » juste à côté d'une carte qui prescrit
    /// justement cette montée en charge — la contradiction que toute cette
    /// fonctionnalité a été conçue pour éliminer, revenue par une autre porte.
    func test_assess_withPlan_onAClosingWeek_neverWarnsFromRawRatio() {
        let g = goal()
        // Trois semaines régulières avant la semaine en cours.
        let baseline = [run("2026-08-03", km: 5.0), run("2026-08-10", km: 5.0), run("2026-08-17", km: 5.0)]
        // 2026-08-29 est un samedi : il ne reste que deux jours à la semaine
        // du 08-24, qui devient donc `.currentWeekClosing` (cible à 0).
        let plan = TrainingPlanner.plan(goal: g, history: baseline, hrMax: 190,
                                        today: date("2026-08-29"), calendar: calendar)
        XCTAssertEqual(plan.weeks.first?.role, .currentWeekClosing)
        let onPlan = [run("2026-08-25", km: 6.0), run("2026-08-27", km: 4.0)]
        let a = TrainingLoadMonitor.assess(history: baseline + onPlan, plan: plan, readiness: nil,
                                           today: date("2026-08-29"), calendar: calendar)
        // Porte de signifiance ouverte (4 semaines sur 4 contiennent une
        // sortie) et ratio brut confortablement au-dessus du seuil :
        // aigu = 10 km, chronique = (5+5+5+10)/4 = 6,25 → ratio = 1,6.
        XCTAssertNotNil(a.acwr)
        XCTAssertGreaterThan(a.acwr ?? 0, 1.3)
        XCTAssertTrue(a.alerts.isEmpty, "un plan actif ne doit jamais laisser le ratio brut alerter")
    }

    // MARK: - Frontière des 28 jours de weeksWithARun

    /// Une sortie exactement 28 jours avant `today` compte (fenêtre
    /// inclusive) ; une sortie 29 jours avant ne compte pas.
    func test_weeksWithARun_includesExactlyTwentyEightDaysAgoButExcludesTwentyNine() {
        let today = date("2026-08-28")
        let boundary = run(dayString(from: "2026-08-28", offsetDays: -28), km: 5.0)
        let justOutside = run(dayString(from: "2026-08-28", offsetDays: -29), km: 5.0)
        XCTAssertEqual(TrainingLoadMonitor.weeksWithARun([boundary], today: today, calendar: calendar), 1)
        XCTAssertEqual(TrainingLoadMonitor.weeksWithARun([justOutside], today: today, calendar: calendar), 0)
    }
}
