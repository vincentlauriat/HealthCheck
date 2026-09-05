import Foundation

/// Orchestration partagée entre `DashboardViewModel.loadWellness()` (macOS)
/// et `CompanionAdvisorViewModel.compute()` (Companion iOS) : lit le store,
/// agrège les séries quotidiennes, et compose les verdicts des moteurs purs
/// (forme, VO2max, charge d'entraînement). Ne connaît pas le poids ni les
/// insights — ce sont des ajouts propres au Mac, composés par l'appelant à
/// partir de ce résultat.
enum WellnessOrchestrator {
    struct Result {
        let readiness: ReadinessScore?
        let vo2Trend: VO2MaxTrend?
        let loadAssessment: LoadAssessment
        let vo2MaxAlert: LoadAlert?
        /// Séries quotidiennes déjà agrégées, réutilisables par l'appelant
        /// (ex. moyennes 7 j/30 j des insights Mac) sans re-fetch.
        let hrDaily: [TrendPoint]
        let sleepNights: [TrendPoint]
    }

    static func compute(store: HealthStore, resolver: SourcePriorityResolver,
                         calendar: Calendar, today: Date) throws -> Result {
        let end = today
        guard
            let d30 = calendar.date(byAdding: .day, value: -30, to: end),
            let d120 = calendar.date(byAdding: .day, value: -120, to: end)
        else {
            return Result(readiness: nil, vo2Trend: nil,
                           loadAssessment: LoadAssessment(acuteKm: 0, chronicWeeklyKm: 0, acwr: nil, alerts: []),
                           vo2MaxAlert: nil, hrDaily: [], sleepNights: [])
        }
        let startOfToday = calendar.startOfDay(for: end)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let hrDaily = try dailyAverages(type: "HKQuantityTypeIdentifierRestingHeartRate", from: d30, to: end,
                                         store: store, resolver: resolver, calendar: calendar)
        let hrvDaily = try dailyAverages(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", from: d30, to: end,
                                          store: store, resolver: resolver, calendar: calendar)
        let sleepNights = SleepAggregator.nightlyHours(
            resolver.resolve(try store.sleepRecords(from: d30, to: end)),
            calendar: calendar
        )

        // « Aujourd'hui » = dernier point s'il date bien d'aujourd'hui
        // (d'hier pour le sommeil : la nuit dernière est rangée sous hier) ;
        // la baseline = tous les points précédents.
        // Rend le `TrendPoint` et non sa seule valeur : c'est lui qui porte le
        // nombre d'échantillons derrière la moyenne du jour, et cette
        // profondeur doit remonter jusqu'à l'affichage.
        func split(_ points: [TrendPoint], latestNoOlderThan cutoff: Date) -> (latest: TrendPoint?, baseline: [Double]) {
            guard let last = points.last else { return (nil, []) }
            guard last.date >= cutoff else { return (nil, points.map(\.value)) }
            return (last, points.dropLast().map(\.value))
        }

        let hr = split(hrDaily, latestNoOlderThan: startOfToday)
        let hrv = split(hrvDaily, latestNoOlderThan: startOfToday)
        let sleep = split(sleepNights, latestNoOlderThan: yesterday)

        // Activité : la veille, seul jour complet — aujourd'hui est partiel.
        //
        // « Complet » au calendrier ne suffit pas. Si la synchro s'est
        // interrompue en cours de journée d'hier, son total n'est qu'une
        // fraction de journée que rien ne distingue d'un jour creux : le
        // 2026-09-04, la base du Mac s'arrêtait au 3 septembre à 10 h 28 et
        // ses 231 kcal de matinée, comparés aux 820 habituels, produisaient à
        // eux seuls un « Récupération conseillée » à 13,8.
        //
        // Le critère retenu ne fixe aucune heure limite — un seuil horaire
        // serait arbitraire et se tromperait sur une journée qui finit tôt.
        // Il est purement factuel : **hier n'est close que si l'on connaît
        // quelque chose de postérieur à elle**. Une journée qui est le dernier
        // jour connu peut avoir été coupée n'importe où ; on ne la note pas.
        //
        // Et ce test se fait **série par série**. Juger hier close parce que
        // les pas continuent après minuit, alors que l'énergie s'est arrêtée à
        // 10 h, rouvrirait exactement le trou qu'il ferme : le total tronqué
        // d'un capteur serait noté comme une journée entière.
        func closedYesterday(type: String) throws -> (yesterday: Double?, baseline: [Double]) {
            let records = resolver.resolve(try store.records(type: type, from: d30, to: end))
            let daily = DailyAggregator.totals(records, calendar: calendar)
            let completeDays = daily.filter { $0.date < startOfToday }
            let isClosed = (records.map(\.endDate).max() ?? .distantPast) >= startOfToday
            return (isClosed ? completeDays.last(where: { $0.date == yesterday })?.value : nil,
                    completeDays.filter { $0.date != yesterday }.map(\.value))
        }

        let energy = try closedYesterday(type: "HKQuantityTypeIdentifierActiveEnergyBurned")
        // Les pas entrent dans la même composante que l'énergie : une journée
        // de marche sans séance ne dépense pas beaucoup, mais elle compte.
        let steps = try closedYesterday(type: "HKQuantityTypeIdentifierStepCount")

        let readiness = HealthScoreEngine.readiness(
            sleep: sleep.latest.flatMap { HealthScoreEngine.sleepScore(lastNightHours: $0.value, baseline: sleep.baseline,
                                                                      sampleCount: $0.sampleCount) },
            restingHeartRate: hr.latest.flatMap { HealthScoreEngine.restingHeartRateScore(today: $0.value, baseline: hr.baseline,
                                                                                         sampleCount: $0.sampleCount) },
            hrv: hrv.latest.flatMap { HealthScoreEngine.hrvScore(today: $0.value, baseline: hrv.baseline,
                                                                sampleCount: $0.sampleCount) },
            activity: HealthScoreEngine.activityBalanceScore(
                yesterdayEnergy: energy.yesterday, energyBaseline: energy.baseline,
                yesterdaySteps: steps.yesterday, stepsBaseline: steps.baseline)
        )

        let vo2Records = try store.records(type: VO2MaxEngine.vo2MaxType, from: d120, to: end)
        let vo2Trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)

        let d28 = calendar.date(byAdding: .day, value: -28, to: startOfToday)!
        let recentHistory = try store.workouts(from: d28, to: calendar.date(byAdding: .day, value: 1, to: startOfToday)!)
        let loadAssessment = TrainingLoadMonitor.assess(history: recentHistory, plan: nil,
                                                          readiness: readiness, today: end, calendar: calendar)
        let vo2MaxAlert = VO2MaxEngine.stagnationAlert(trend: vo2Trend, chronicKm: loadAssessment.chronicWeeklyKm)

        return Result(readiness: readiness, vo2Trend: vo2Trend, loadAssessment: loadAssessment,
                      vo2MaxAlert: vo2MaxAlert, hrDaily: hrDaily, sleepNights: sleepNights)
    }

    private static func dailyAverages(type: String, from: Date, to: Date,
                                       store: HealthStore, resolver: SourcePriorityResolver,
                                       calendar: Calendar) throws -> [TrendPoint] {
        DailyAggregator.averages(
            resolver.resolve(try store.records(type: type, from: from, to: to)),
            calendar: calendar
        )
    }
}
