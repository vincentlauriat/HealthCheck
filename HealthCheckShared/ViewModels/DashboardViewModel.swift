import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var today: PeriodSummary?
    @Published private(set) var thisWeek: PeriodSummary?
    @Published private(set) var lastWeek: PeriodSummary?
    @Published private(set) var readiness: ReadinessScore?
    @Published private(set) var insights: [Insight] = []
    @Published private(set) var dailyAdvice: DailyAdvice?

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
        today = try PeriodSummaryEngine.today(store: store, resolver: resolver, calendar: calendar, now: now())
    }

    func loadThisWeek() throws {
        let week = try PeriodSummaryEngine.weekToDate(store: store, resolver: resolver,
                                                      calendar: calendar, now: now())
        thisWeek = week.thisWeek
        lastWeek = week.lastWeek
    }

    /// Calcule le score de forme (baselines 30 j) et les insights.
    /// À appeler après `loadThisWeek()` — les insights de pas comparent
    /// les agrégats hebdomadaires déjà chargés.
    func loadWellness() throws {
        let end = now()
        let wellness = try WellnessOrchestrator.compute(store: store, resolver: resolver, calendar: calendar, today: end)
        readiness = wellness.readiness

        guard let d30 = calendar.date(byAdding: .day, value: -30, to: end) else { return }

        let weightDaily = try dailyAverages(type: "HKQuantityTypeIdentifierBodyMass", from: d30, to: end)
        var weightDelta30d: Double?
        if let first = weightDaily.first?.value, let last = weightDaily.last?.value {
            weightDelta30d = last - first
        }
        let inputs = InsightInputsBuilder.build(wellness: wellness, thisWeek: thisWeek, lastWeek: lastWeek,
                                                weightDelta30d: weightDelta30d, calendar: calendar, today: end)
        let weightTrend = WeightEngine.trend(weights: weightDaily, today: end, calendar: calendar)
        let weightSafetyAlert = WeightEngine.safetyAlert(
            trend: weightTrend,
            trainingLoadElevated: wellness.loadAssessment.alerts.contains { $0.severity == .warning }
        )
        dailyAdvice = DailyAdviceEngine.advise(readiness: wellness.readiness, loadAlerts: wellness.loadAssessment.alerts,
                                               vo2MaxAlert: wellness.vo2MaxAlert, weightAlert: weightSafetyAlert)

        insights = InsightsEngine.generate(from: inputs)
    }

    private func dailyAverages(type: String, from: Date, to: Date) throws -> [TrendPoint] {
        DailyAggregator.averages(
            resolver.resolve(try store.records(type: type, from: from, to: to)),
            calendar: calendar
        )
    }

}
