import Foundation

/// Réplique `DashboardViewModel.loadWellness()` (macOS) contre le
/// `HealthStore` local du Companion — jamais celui du Mac. Sans les
/// insights d'activité/pas (hors périmètre de cet écran) et sans le poids
/// (spec §2 : « balance = territoire Withings », le poids reste exclusif
/// au Mac).
@MainActor
final class CompanionAdvisorViewModel: ObservableObject {
    @Published private(set) var readiness: ReadinessScore?
    @Published private(set) var dailyAdvice: DailyAdvice?
    @Published private(set) var vo2Trend: VO2MaxTrend?
    @Published private(set) var hasLoaded = false
    @Published private(set) var storeUnavailable = false

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, resolver: SourcePriorityResolver,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
    }

    /// Ne lève jamais — contrairement à `DashboardViewModel.load()`, un
    /// store indisponible est un état normal de cet écran (§`storeUnavailable`),
    /// pas une raison d'empêcher toute la scène de démarrer comme sur le Mac.
    func refresh() {
        hasLoaded = true
        do {
            try compute()
            storeUnavailable = false
        } catch {
            storeUnavailable = true
            readiness = nil
            dailyAdvice = nil
            vo2Trend = nil
        }
    }

    private func compute() throws {
        let end = now()
        guard
            let d30 = calendar.date(byAdding: .day, value: -30, to: end),
            let d120 = calendar.date(byAdding: .day, value: -120, to: end)
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
        // (d'hier pour le sommeil) ; la baseline = tous les points
        // précédents. Identique à DashboardViewModel.loadWellness().
        func split(_ points: [TrendPoint], latestNoOlderThan cutoff: Date) -> (latest: Double?, baseline: [Double]) {
            guard let last = points.last else { return (nil, []) }
            guard last.date >= cutoff else { return (nil, points.map(\.value)) }
            return (last.value, points.dropLast().map(\.value))
        }

        let hr = split(hrDaily, latestNoOlderThan: startOfToday)
        let hrv = split(hrvDaily, latestNoOlderThan: startOfToday)
        let sleep = split(sleepNights, latestNoOlderThan: yesterday)

        let completeDays = energyDaily.filter { $0.date < startOfToday }
        let yesterdayEnergy = completeDays.last(where: { $0.date == yesterday })?.value
        let energyBaseline = completeDays.filter { $0.date != yesterday }.map(\.value)

        let computedReadiness = HealthScoreEngine.readiness(
            sleep: sleep.latest.flatMap { HealthScoreEngine.sleepScore(lastNightHours: $0, baseline: sleep.baseline) },
            restingHeartRate: hr.latest.flatMap { HealthScoreEngine.restingHeartRateScore(today: $0, baseline: hr.baseline) },
            hrv: hrv.latest.flatMap { HealthScoreEngine.hrvScore(today: $0, baseline: hrv.baseline) },
            activity: yesterdayEnergy.flatMap { HealthScoreEngine.activityBalanceScore(yesterday: $0, baseline: energyBaseline) }
        )
        readiness = computedReadiness

        let vo2Records = try store.records(type: VO2MaxEngine.vo2MaxType, from: d120, to: end)
        let trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)
        vo2Trend = trend

        let d28 = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: end))!
        let recentHistory = try store.workouts(from: d28, to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!)
        let loadAssessment = TrainingLoadMonitor.assess(history: recentHistory, plan: nil,
                                                         readiness: computedReadiness, today: end, calendar: calendar)
        let vo2MaxAlert = VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: loadAssessment.chronicWeeklyKm)

        dailyAdvice = DailyAdviceEngine.advise(readiness: computedReadiness, loadAlerts: loadAssessment.alerts,
                                               vo2MaxAlert: vo2MaxAlert, weightAlert: nil)
    }

    private func dailyAverages(type: String, from: Date, to: Date) throws -> [TrendPoint] {
        DailyAggregator.averages(
            resolver.resolve(try store.records(type: type, from: from, to: to)),
            calendar: calendar
        )
    }
}
