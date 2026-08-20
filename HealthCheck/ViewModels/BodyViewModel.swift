import Foundation

@MainActor
final class BodyViewModel: ObservableObject {
    /// Photographies de la période affichée (graphiques).
    @Published private(set) var snapshots: [BodySnapshot] = []
    /// Dernière pesée connue, toutes périodes confondues.
    @Published private(set) var latest: BodySnapshot?
    @Published private(set) var weightDelta30d: Double?
    @Published private(set) var fatMassDelta30d: Double?
    @Published private(set) var leanMassDelta30d: Double?
    @Published private(set) var weightDelta1y: Double?
    /// Mesures Withings sans équivalent HealthKit (présentes uniquement après
    /// une synchro API) : dernière valeur connue, nil si jamais synchronisé.
    @Published private(set) var latestMuscleMass: Double?
    @Published private(set) var latestHydration: Double?
    @Published private(set) var latestBoneMass: Double?
    @Published private(set) var latestVisceralFat: Double?

    /// Arbre de répartition du poids pour le Sankey (nil sans % de graisse).
    var weightSankey: WeightSankey? {
        guard let latest else { return nil }
        return BodyCompositionEngine.weightSankey(
            weight: latest.weight,
            fatMass: latest.fatMass,
            muscle: latestMuscleMass,
            bone: latestBoneMass
        )
    }

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

    func load(period: TrendPeriod) throws {
        hasLoaded = true
        let end = now()
        // L'historique complet reste petit (~4 000 pesées) : on le charge en
        // entier pour que la dernière pesée et les deltas ne dépendent pas de
        // la période choisie pour les graphiques.
        let all = BodyCompositionEngine.dailySnapshots(
            weights: try daily("HKQuantityTypeIdentifierBodyMass", to: end),
            fatShares: try daily("HKQuantityTypeIdentifierBodyFatPercentage", to: end),
            leanMasses: try daily("HKQuantityTypeIdentifierLeanBodyMass", to: end),
            bmis: try daily("HKQuantityTypeIdentifierBodyMassIndex", to: end)
        )
        let start = period.startDate(now: end, calendar: calendar)
        snapshots = all.filter { $0.day >= start }
        latest = all.last

        // Les deltas sont ancrés sur la dernière pesée, pas sur aujourd'hui :
        // si la balance n'a pas servi depuis deux mois, « il y a 30 jours »
        // doit rester un écart entre deux pesées réelles.
        guard let latest else {
            weightDelta30d = nil; fatMassDelta30d = nil; leanMassDelta30d = nil; weightDelta1y = nil
            return
        }
        let ref30 = reference(in: all, daysBefore: 30, anchor: latest.day)
        weightDelta30d = ref30.map { latest.weight - $0.weight }
        fatMassDelta30d = sub(latest.fatMass, ref30?.fatMass)
        leanMassDelta30d = sub(latest.leanMass, ref30?.leanMass)
        weightDelta1y = reference(in: all, daysBefore: 365, anchor: latest.day).map { latest.weight - $0.weight }

        latestMuscleMass = try daily(WithingsMapper.muscleMassType, to: end).last?.value
        latestHydration = try daily(WithingsMapper.hydrationType, to: end).last?.value
        latestBoneMass = try daily(WithingsMapper.boneMassType, to: end).last?.value
        latestVisceralFat = try daily(WithingsMapper.visceralFatType, to: end).last?.value
    }

    private func daily(_ type: String, to end: Date) throws -> [TrendPoint] {
        DailyAggregator.averages(resolver.resolve(try store.records(type: type, from: .distantPast, to: end)), calendar: calendar)
    }

    private func reference(in all: [BodySnapshot], daysBefore days: Int, anchor: Date) -> BodySnapshot? {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: anchor) else { return nil }
        return BodyCompositionEngine.reference(in: all, onOrBefore: cutoff)
    }

    private func sub(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }
}
