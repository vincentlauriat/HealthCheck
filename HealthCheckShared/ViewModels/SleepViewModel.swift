import Foundation

@MainActor
final class SleepViewModel: ObservableObject {
    @Published private(set) var nights: [NightSummary] = []
    @Published private(set) var lastNight: NightSummary?
    @Published private(set) var averageHours: Double?
    @Published private(set) var averageScore: Double?
    @Published private(set) var averageDeepShare: Double?
    @Published private(set) var averageRemShare: Double?

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

    /// Charge les 14 dernières nuits (fenêtre de 21 jours pour absorber
    /// les nuits non trackées).
    /// Vrai après le premier chargement — les vues ne rechargent pas à
    /// chaque passage de section, seulement via les onChange d'import/synchro.
    @Published private(set) var hasLoaded = false

    func load() throws {
        hasLoaded = true
        let end = now()
        guard let start = calendar.date(byAdding: .day, value: -21, to: end) else { return }
        let resolved = resolver.resolve(try store.sleepRecords(from: start, to: end))
        let all = SleepScoreEngine.summarize(resolved, calendar: calendar)
        nights = Array(all.suffix(14))
        lastNight = nights.last

        guard !nights.isEmpty else {
            averageHours = nil; averageScore = nil; averageDeepShare = nil; averageRemShare = nil
            return
        }
        let count = Double(nights.count)
        averageHours = nights.map(\.asleepHours).reduce(0, +) / count
        averageScore = nights.map(\.score).reduce(0, +) / count
        let totalAsleep = nights.map(\.asleepHours).reduce(0, +)
        averageDeepShare = totalAsleep > 0 ? nights.map(\.deepHours).reduce(0, +) / totalAsleep : nil
        averageRemShare = totalAsleep > 0 ? nights.map(\.remHours).reduce(0, +) / totalAsleep : nil
    }
}
