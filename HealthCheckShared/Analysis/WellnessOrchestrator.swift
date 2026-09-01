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
        let energyDaily = DailyAggregator.totals(
            resolver.resolve(try store.records(type: "HKQuantityTypeIdentifierActiveEnergyBurned", from: d30, to: end)),
            calendar: calendar
        )
        let sleepNights = SleepAggregator.nightlyHours(
            resolver.resolve(try store.sleepRecords(from: d30, to: end)),
            calendar: calendar
        )

        // « Aujourd'hui » = dernier point s'il date bien d'aujourd'hui
        // (d'hier pour le sommeil : la nuit dernière est rangée sous hier) ;
        // la baseline = tous les points précédents.
        func split(_ points: [TrendPoint], latestNoOlderThan cutoff: Date) -> (latest: Double?, baseline: [Double]) {
            guard let last = points.last else { return (nil, []) }
            guard last.date >= cutoff else { return (nil, points.map(\.value)) }
            return (last.value, points.dropLast().map(\.value))
        }

        let hr = split(hrDaily, latestNoOlderThan: startOfToday)
        let hrv = split(hrvDaily, latestNoOlderThan: startOfToday)
        let sleep = split(sleepNights, latestNoOlderThan: yesterday)

        // Activité : la veille, seul jour complet — aujourd'hui est partiel.
        let completeDays = energyDaily.filter { $0.date < startOfToday }
        let yesterdayEnergy = completeDays.last(where: { $0.date == yesterday })?.value
        let energyBaseline = completeDays.filter { $0.date != yesterday }.map(\.value)

        let readiness = HealthScoreEngine.readiness(
            sleep: sleep.latest.flatMap { HealthScoreEngine.sleepScore(lastNightHours: $0, baseline: sleep.baseline) },
            restingHeartRate: hr.latest.flatMap { HealthScoreEngine.restingHeartRateScore(today: $0, baseline: hr.baseline) },
            hrv: hrv.latest.flatMap { HealthScoreEngine.hrvScore(today: $0, baseline: hrv.baseline) },
            activity: yesterdayEnergy.flatMap { HealthScoreEngine.activityBalanceScore(yesterday: $0, baseline: energyBaseline) }
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
