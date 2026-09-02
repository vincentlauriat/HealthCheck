import Foundation

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published private(set) var today: DayStrain?
    @Published private(set) var history: [DayStrain] = []
    @Published private(set) var maxHeartRate: Double?
    @Published private(set) var todayActiveEnergy: Double?
    @Published private(set) var todayExerciseMinutes: Double?

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

    /// Vrai après le premier chargement — les vues ne rechargent pas à
    /// chaque passage de section, seulement via les onChange d'import/synchro.
    @Published private(set) var hasLoaded = false

    func load() throws {
        hasLoaded = true
        let end = now()
        guard
            let d14 = calendar.date(byAdding: .day, value: -14, to: end),
            let d2y = calendar.date(byAdding: .year, value: -2, to: end)
        else { return }

        // FC max observée sur 2 ans (agrégat SQL — 388k lignes restent en base),
        // bornée à une plage physiologique plausible.
        guard let observedMax = try store.maxValue(type: "HKQuantityTypeIdentifierHeartRate", from: d2y, to: end) else {
            return
        }
        let maxHR = min(max(observedMax, 140), 210)
        maxHeartRate = maxHR

        // Les échantillons de FC sont ponctuels (start == end) : jamais de
        // chevauchement d'intervalles, donc pas de résolution de priorité de
        // source — et les doublons iPhone/Watch au même instant pèsent 0 min
        // dans le calcul par écart-au-suivant.
        let samples = try store.records(type: "HKQuantityTypeIdentifierHeartRate", from: d14, to: end)
        history = StrainEngine.dayStrains(samples: samples, maxHeartRate: maxHR, calendar: calendar)

        let startOfToday = calendar.startOfDay(for: end)
        today = history.last(where: { $0.day == startOfToday })

        let energy = DailyAggregator.totals(
            resolver.resolve(try store.records(type: "HKQuantityTypeIdentifierActiveEnergyBurned", from: startOfToday, to: end)),
            calendar: calendar
        )
        todayActiveEnergy = energy.last?.value
        let exercise = DailyAggregator.totals(
            resolver.resolve(try store.records(type: "HKQuantityTypeIdentifierAppleExerciseTime", from: startOfToday, to: end)),
            calendar: calendar
        )
        todayExerciseMinutes = exercise.last?.value
    }
}
