import Foundation

struct PeriodSummary {
    let steps: Double
    let distanceKm: Double
    let activeEnergyKcal: Double
    let exerciseMinutes: Double
    let restingHeartRate: Double?
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var today: PeriodSummary?
    @Published private(set) var thisWeek: PeriodSummary?
    @Published private(set) var lastWeek: PeriodSummary?
    @Published private(set) var readiness: ReadinessScore?
    @Published private(set) var insights: [Insight] = []

    /// Vrai après le premier chargement — l'accueil ne recalcule pas à chaque
    /// retour de section, seulement via les refresh explicites d'import/synchro.
    @Published private(set) var hasLoaded = false

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, resolver: SourcePriorityResolver, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
    }

    func load() throws {
        hasLoaded = true
        try loadToday()
        try loadThisWeek()
        try loadWellness()
    }

    func loadToday() throws {
        let startOfDay = calendar.startOfDay(for: now())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        today = try summary(from: startOfDay, to: endOfDay)
    }

    func loadThisWeek() throws {
        let currentDate = now()
        let interval = calendar.dateInterval(of: .weekOfYear, for: currentDate)!
        thisWeek = try summary(from: interval.start, to: interval.end)

        // Comparaison à période écoulée égale : mercredi 15h se compare au
        // mercredi 15h de la semaine passée, pas à sa semaine complète.
        if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start) {
            let elapsed = currentDate.timeIntervalSince(interval.start)
            lastWeek = try summary(from: lastWeekStart, to: lastWeekStart.addingTimeInterval(elapsed))
        }
    }

    /// Calcule le score de forme (baselines 30 j) et les insights.
    /// À appeler après `loadThisWeek()` — les insights de pas comparent
    /// les agrégats hebdomadaires déjà chargés.
    func loadWellness() throws {
        let end = now()
        guard
            let d30 = calendar.date(byAdding: .day, value: -30, to: end),
            let d120 = calendar.date(byAdding: .day, value: -120, to: end),
            let d7 = calendar.date(byAdding: .day, value: -7, to: end)
        else { return }
        let startOfToday = calendar.startOfDay(for: end)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let hrDaily = try dailyAverages(type: "HKQuantityTypeIdentifierRestingHeartRate", from: d30, to: end)
        let hrvDaily = try dailyAverages(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", from: d30, to: end)
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

        readiness = HealthScoreEngine.readiness(
            sleep: sleep.latest.flatMap { HealthScoreEngine.sleepScore(lastNightHours: $0, baseline: sleep.baseline) },
            restingHeartRate: hr.latest.flatMap { HealthScoreEngine.restingHeartRateScore(today: $0, baseline: hr.baseline) },
            hrv: hrv.latest.flatMap { HealthScoreEngine.hrvScore(today: $0, baseline: hrv.baseline) },
            activity: yesterdayEnergy.flatMap { HealthScoreEngine.activityBalanceScore(yesterday: $0, baseline: energyBaseline) }
        )

        var inputs = InsightInputs()
        inputs.restingHRMean7 = mean(hrDaily.filter { $0.date >= d7 }.map(\.value))
        inputs.restingHRMean30 = mean(hrDaily.map(\.value))
        // Au moins 3 nuits trackées, sinon la moyenne ne veut rien dire
        // (une seule sieste enregistrée déclencherait « dette de sommeil »).
        let recentNights = sleepNights.filter { $0.date >= d7 }
        inputs.sleepHoursMean7 = recentNights.count >= 3 ? mean(recentNights.map(\.value)) : nil
        inputs.stepsThisWeek = thisWeek?.steps
        inputs.stepsLastWeek = lastWeek?.steps
        let vo2Records = try store.records(type: VO2MaxEngine.vo2MaxType, from: d120, to: end)
        inputs.vo2Trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)
        let weightDaily = try dailyAverages(type: "HKQuantityTypeIdentifierBodyMass", from: d30, to: end)
        if let first = weightDaily.first?.value, let last = weightDaily.last?.value {
            inputs.weightDelta30d = last - first
        }
        insights = InsightsEngine.generate(from: inputs)
    }

    private func dailyAverages(type: String, from: Date, to: Date) throws -> [TrendPoint] {
        DailyAggregator.averages(
            resolver.resolve(try store.records(type: type, from: from, to: to)),
            calendar: calendar
        )
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func summary(from: Date, to: Date) throws -> PeriodSummary {
        let steps = try sum(type: "HKQuantityTypeIdentifierStepCount", from: from, to: to)
        let distance = try sum(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", from: from, to: to)
        let energy = try sum(type: "HKQuantityTypeIdentifierActiveEnergyBurned", from: from, to: to)
        let exercise = try sum(type: "HKQuantityTypeIdentifierAppleExerciseTime", from: from, to: to)
        let restingHR = try resolver
            .resolve(store.records(type: "HKQuantityTypeIdentifierRestingHeartRate", from: from, to: to))
            .sorted(by: { $0.startDate > $1.startDate })
            .first?.value

        return PeriodSummary(steps: steps, distanceKm: distance, activeEnergyKcal: energy, exerciseMinutes: exercise, restingHeartRate: restingHR)
    }

    private func sum(type: String, from: Date, to: Date) throws -> Double {
        resolver.resolve(try store.records(type: type, from: from, to: to)).reduce(0) { $0 + $1.value }
    }
}
