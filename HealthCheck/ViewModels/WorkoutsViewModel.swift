import Foundation

/// Séance enrichie pour l'affichage : libellé français, durée normalisée,
/// FC moyenne pendant la séance (agrégat SQL sur la FC continue).
struct WorkoutItem: Equatable {
    let label: String
    let startDate: Date
    let minutes: Double
    let distanceKm: Double?
    let energyKcal: Double?
    let averageHeartRate: Double?
    /// URL locale de la trace GPX si elle a été copiée lors d'un import.
    let routeURL: URL?
}

@MainActor
final class WorkoutsViewModel: ObservableObject {
    @Published private(set) var recentWorkouts: [WorkoutItem] = []
    @Published private(set) var weeklyVolumes: [WeekVolume] = []
    @Published private(set) var thisWeekCount = 0
    @Published private(set) var thisWeekMinutes = 0.0
    @Published private(set) var thisWeekKcal = 0.0

    private let store: HealthStore
    private let routeStore: RouteStore
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, routeStore: RouteStore = RouteStore(), calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.routeStore = routeStore
        self.calendar = calendar
        self.now = now
    }

    /// Vrai après le premier chargement — les vues ne rechargent pas à
    /// chaque passage de section, seulement via les onChange d'import/synchro.
    @Published private(set) var hasLoaded = false

    func load() throws {
        hasLoaded = true
        let end = now()
        guard let chartStart = calendar.date(byAdding: .weekOfYear, value: -12, to: end) else { return }
        let workouts = try store.workouts(from: chartStart, to: end)

        weeklyVolumes = WorkoutStatsEngine.weeklyVolumes(workouts, weeks: 12, now: end, calendar: calendar)

        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: end)?.start {
            let thisWeek = workouts.filter { $0.startDate >= weekStart }
            thisWeekCount = thisWeek.count
            thisWeekMinutes = thisWeek.reduce(0) { $0 + WorkoutStatsEngine.durationMinutes($1) }
            thisWeekKcal = thisWeek.reduce(0) { $0 + ($1.totalEnergyBurned ?? 0) }
        }

        // Les 25 dernières séances, FC moyenne calculée en SQL par séance —
        // 25 requêtes d'agrégat, jamais les échantillons en mémoire.
        recentWorkouts = try workouts.suffix(25).reversed().map { workout in
            WorkoutItem(
                label: WorkoutStatsEngine.label(for: workout.activityType),
                startDate: workout.startDate,
                minutes: WorkoutStatsEngine.durationMinutes(workout),
                distanceKm: workout.totalDistance,
                energyKcal: workout.totalEnergyBurned,
                averageHeartRate: try store.averageValue(
                    type: "HKQuantityTypeIdentifierHeartRate",
                    from: workout.startDate,
                    to: workout.endDate.addingTimeInterval(1)
                ),
                routeURL: workout.routeFileName.flatMap(routeStore.url(forRouteFileName:))
            )
        }
    }
}
