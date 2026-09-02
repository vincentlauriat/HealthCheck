import Foundation

/// Ce que la passe détachée rapporte au `MainActor` : tout est calculé hors
/// du fil principal, l'application du résultat n'est plus qu'une affectation.
struct CompanionHomeSnapshot {
    let wellness: WellnessOrchestrator.Result
    let today: PeriodSummary
    let thisWeek: PeriodSummary
    let lastWeek: PeriodSummary?
    let insights: [Insight]
}

/// Accueil du Companion : forme, conseil du jour, tendance VO2max, résumés du
/// jour et de la semaine, observations. Tout est calculé contre le
/// `HealthStore` local de l'iPhone — jamais celui du Mac — par les mêmes
/// fonctions partagées que l'Accueil macOS (`WellnessOrchestrator`,
/// `PeriodSummaryEngine`, `InsightInputsBuilder`). Sans le poids : l'iPhone
/// n'a pas de pesée en base avant le SP5.
@MainActor
final class CompanionAdvisorViewModel: ObservableObject {
    @Published private(set) var readiness: ReadinessScore?
    @Published private(set) var dailyAdvice: DailyAdvice?
    @Published private(set) var vo2Trend: VO2MaxTrend?
    @Published private(set) var vo2MaxAlert: LoadAlert?
    @Published private(set) var today: PeriodSummary?
    @Published private(set) var thisWeek: PeriodSummary?
    @Published private(set) var lastWeek: PeriodSummary?
    @Published private(set) var insights: [Insight] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var storeUnavailable = false

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date
    /// Injectable pour les seules gardes qui exigent de suspendre le calcul en
    /// plein vol (état de chargement, résultat périmé) ; en production c'est
    /// toujours la composition ci-dessous.
    private let compute: @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> CompanionHomeSnapshot
    /// Discrimine deux `refresh()` concurrents : seul le plus récent a le
    /// droit d'écrire dans les `@Published`. Sans ceci, un retour au premier
    /// plan pendant un pull-to-refresh pourrait appliquer le résultat le plus
    /// ancien, simplement parce qu'il a fini en dernier.
    private var generation = 0

    init(store: HealthStore, resolver: SourcePriorityResolver,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         compute: @escaping @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> CompanionHomeSnapshot
            = CompanionAdvisorViewModel.defaultCompute) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
        self.compute = compute
    }

    /// `weightDelta30d` reste `nil` : l'iPhone n'a aucune pesée en base avant
    /// le SP5, et `InsightsEngine` traite l'absence comme une absence, jamais
    /// comme un zéro.
    static let defaultCompute: @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> CompanionHomeSnapshot = {
        store, resolver, calendar, today in
        let wellness = try WellnessOrchestrator.compute(store: store, resolver: resolver,
                                                        calendar: calendar, today: today)
        let week = try PeriodSummaryEngine.weekToDate(store: store, resolver: resolver,
                                                      calendar: calendar, now: today)
        let inputs = InsightInputsBuilder.build(wellness: wellness, thisWeek: week.thisWeek,
                                                lastWeek: week.lastWeek, weightDelta30d: nil,
                                                calendar: calendar, today: today)
        return CompanionHomeSnapshot(
            wellness: wellness,
            today: try PeriodSummaryEngine.today(store: store, resolver: resolver,
                                                 calendar: calendar, now: today),
            thisWeek: week.thisWeek,
            lastWeek: week.lastWeek,
            insights: InsightsEngine.generate(from: inputs))
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
        // Nommée `asOf` et pas `today` : la propriété publiée `today` porte le
        // résumé du jour, la collision de noms est un piège à relecture.
        let asOf = now()
        let compute = self.compute

        let outcome = await Task.detached(priority: .userInitiated) {
            Result<CompanionHomeSnapshot, Error>(catching: {
                try compute(store, resolver, calendar, asOf)
            })
        }.value

        // Un `refresh()` plus récent a été lancé pendant le calcul : son
        // résultat fait foi, celui-ci est périmé.
        guard token == generation else { return }

        // Posé seulement ici : le laisser à `true` pendant le calcul
        // afficherait « Pas encore assez de données » (état `hasLoaded` +
        // valeurs encore nulles) le temps de la lecture — soit précisément
        // plusieurs secondes dans le cas que ce déport hors du `MainActor`
        // sert à couvrir.
        hasLoaded = true

        switch outcome {
        case .success(let snapshot):
            apply(snapshot)
            storeUnavailable = false
        case .failure:
            storeUnavailable = true
            readiness = nil
            dailyAdvice = nil
            vo2Trend = nil
            vo2MaxAlert = nil
            today = nil
            thisWeek = nil
            lastWeek = nil
            insights = []
        }
    }

    private func apply(_ snapshot: CompanionHomeSnapshot) {
        let wellness = snapshot.wellness
        readiness = wellness.readiness
        vo2Trend = wellness.vo2Trend
        vo2MaxAlert = wellness.vo2MaxAlert
        dailyAdvice = DailyAdviceEngine.advise(readiness: wellness.readiness, loadAlerts: wellness.loadAssessment.alerts,
                                               vo2MaxAlert: wellness.vo2MaxAlert, weightAlert: nil)
        today = snapshot.today
        thisWeek = snapshot.thisWeek
        lastWeek = snapshot.lastWeek
        insights = snapshot.insights
    }
}
