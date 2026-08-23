import Foundation

/// Couche de composition entre le store, les trois moteurs d'analyse
/// (`TrainingPlanner`, `SessionMatcher`, `TrainingLoadMonitor`) et l'écran.
/// Ne recalcule rien elle-même : elle lit l'objectif actif, rassemble
/// l'historique et la FC max, puis délègue tout le calcul aux moteurs —
/// ce qui garantit que le plan affiché est toujours celui que produirait
/// un appel direct à `TrainingPlanner.plan(...)` pour les mêmes entrées.
@MainActor
final class TrainingViewModel: ObservableObject {
    @Published private(set) var goal: RaceGoal?
    @Published private(set) var plan: TrainingPlan?
    @Published private(set) var progress: WeekProgress?
    @Published private(set) var assessment: LoadAssessment?

    /// Vrai après le premier chargement — même sémantique que
    /// `WorkoutsViewModel.hasLoaded`.
    @Published private(set) var hasLoaded = false

    private let store: HealthStore
    private let calendar: Calendar
    private let now: () -> Date

    private static let historyWindowDays = 90
    private static let hrMaxWindowDays = 180
    private static let heartRateType = "HKQuantityTypeIdentifierHeartRate"
    private static let defaultHRMax = 190.0

    init(store: HealthStore, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    /// `readiness` est une entrée, pas quelque chose que cette vue calcule :
    /// le score de forme du jour est déjà publié par `DashboardViewModel`
    /// et l'appelant le transmet ici (voir tâche 7). Le reconstruire dans
    /// ce view model dupliquerait la logique de `DashboardViewModel.loadWellness()`.
    func load(readiness: ReadinessScore? = nil) throws {
        hasLoaded = true
        let end = now()
        let goals = try store.raceGoals()
        let activeGoal = RaceGoal.active(in: goals, today: end, calendar: calendar)
        goal = activeGoal

        let historyStart = calendar.date(byAdding: .day, value: -Self.historyWindowDays, to: end)!
        let history = try store.workouts(from: historyStart, to: end)

        // Sans objectif actif, le plan et la progression n'ont pas de sens,
        // mais le moniteur de charge, lui, reste pertinent : la branche
        // « sans plan » (alertes ACWR brutes) fonctionne comme un simple
        // suivi de charge entre deux courses — elle ne doit pas dépendre
        // d'un objectif pour s'exécuter.
        guard let activeGoal else {
            plan = nil
            progress = nil
            assessment = TrainingLoadMonitor.assess(history: history, plan: nil, readiness: readiness,
                                                     today: end, calendar: calendar)
            return
        }

        // Agrégat SQL indexé — jamais un join ni un chargement des
        // échantillons de FC continue (des millions de lignes).
        let hrMaxCutoff = calendar.date(byAdding: .day, value: -Self.hrMaxWindowDays, to: end)!
        let hrMax = (try? store.maxValue(type: Self.heartRateType, from: hrMaxCutoff, to: end))
            .flatMap { $0 } ?? Self.defaultHRMax

        let computedPlan = TrainingPlanner.plan(goal: activeGoal, history: history, hrMax: hrMax,
                                                 today: end, calendar: calendar)
        plan = computedPlan

        let currentMonday = TrainingPlanner.monday(of: end, calendar: calendar)
        if let currentWeek = computedPlan.weeks.first(where: { $0.monday == currentMonday }) {
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: currentWeek.monday)!
            let executed = history.filter { $0.startDate >= currentWeek.monday && $0.startDate < weekEnd }
            progress = SessionMatcher.match(week: currentWeek, executed: executed)
        } else {
            progress = nil
        }

        assessment = TrainingLoadMonitor.assess(history: history, plan: computedPlan,
                                                readiness: readiness, today: end, calendar: calendar)
    }

    func createGoal(name: String, raceDate: Date, distanceKm: Double, elevationGainM: Double) throws {
        let newGoal = RaceGoal(id: UUID().uuidString, name: name, raceDate: raceDate,
                               distanceKm: distanceKm, elevationGainM: elevationGainM,
                               objective: .finishComfortable, createdAt: now())
        try store.saveRaceGoal(newGoal)
    }

    func deleteActiveGoal() throws {
        guard let goal else { return }
        try store.deleteRaceGoal(id: goal.id)
    }
}
