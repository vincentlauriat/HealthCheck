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
    @Published private(set) var vo2MaxAlert: LoadAlert?
    @Published private(set) var hasLoaded = false
    @Published private(set) var storeUnavailable = false

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date
    /// Injectable pour les seules gardes qui exigent de suspendre le calcul en
    /// plein vol (état de chargement, résultat périmé) ; en production c'est
    /// toujours `WellnessOrchestrator.compute`.
    private let compute: @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> WellnessOrchestrator.Result
    /// Discrimine deux `refresh()` concurrents : seul le plus récent a le
    /// droit d'écrire dans les `@Published`. Sans ceci, un retour au premier
    /// plan pendant un pull-to-refresh pourrait appliquer le résultat le plus
    /// ancien, simplement parce qu'il a fini en dernier.
    private var generation = 0

    init(store: HealthStore, resolver: SourcePriorityResolver,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         compute: @escaping @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> WellnessOrchestrator.Result
            = { try WellnessOrchestrator.compute(store: $0, resolver: $1, calendar: $2, today: $3) }) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
        self.compute = compute
    }

    /// Ne lève jamais — contrairement à `DashboardViewModel.load()`, un
    /// store indisponible est un état normal de cet écran (§`storeUnavailable`),
    /// pas une raison d'empêcher toute la scène de démarrer comme sur le Mac.
    ///
    /// Les lectures GRDB (30 j de FC/HRV/énergie/sommeil + 120 j de séances)
    /// se font hors du `MainActor` : sur l'iPhone elles partagent la base avec
    /// l'import HealthKit et peuvent attendre son verrou d'écriture plusieurs
    /// secondes. Seul le calcul est déporté ; l'application du résultat
    /// revient sur le `MainActor`.
    func refresh() async {
        generation &+= 1
        let token = generation
        let store = self.store
        let resolver = self.resolver
        let calendar = self.calendar
        let today = now()
        let compute = self.compute

        let outcome = await Task.detached(priority: .userInitiated) {
            Result<WellnessOrchestrator.Result, Error>(catching: {
                try compute(store, resolver, calendar, today)
            })
        }.value

        // Un `refresh()` plus récent a été lancé pendant le calcul : son
        // résultat fait foi, celui-ci est périmé.
        guard token == generation else { return }

        // Posé seulement ici : le laisser à `true` pendant le calcul
        // afficherait « Pas encore assez de données » (état `hasLoaded` +
        // trois valeurs encore nulles) le temps de la lecture — soit
        // précisément plusieurs secondes dans le cas que ce déport hors du
        // `MainActor` sert à couvrir.
        hasLoaded = true

        switch outcome {
        case .success(let wellness):
            apply(wellness)
            storeUnavailable = false
        case .failure:
            storeUnavailable = true
            readiness = nil
            dailyAdvice = nil
            vo2Trend = nil
            vo2MaxAlert = nil
        }
    }

    private func apply(_ wellness: WellnessOrchestrator.Result) {
        readiness = wellness.readiness
        vo2Trend = wellness.vo2Trend
        vo2MaxAlert = wellness.vo2MaxAlert
        dailyAdvice = DailyAdviceEngine.advise(readiness: wellness.readiness, loadAlerts: wellness.loadAssessment.alerts,
                                               vo2MaxAlert: wellness.vo2MaxAlert, weightAlert: nil)
    }
}
