import Foundation

/// Calcule forme/VO2max/conseil du jour via `WellnessOrchestrator`
/// (partagé avec `DashboardViewModel.loadWellness()` macOS) contre le
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
        let wellness = try WellnessOrchestrator.compute(store: store, resolver: resolver, calendar: calendar, today: now())
        readiness = wellness.readiness
        vo2Trend = wellness.vo2Trend
        dailyAdvice = DailyAdviceEngine.advise(readiness: wellness.readiness, loadAlerts: wellness.loadAssessment.alerts,
                                               vo2MaxAlert: wellness.vo2MaxAlert, weightAlert: nil)
    }
}
