import Foundation

enum TrendPeriod: Hashable {
    case oneWeek
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case all

    func startDate(now: Date, calendar: Calendar) -> Date {
        switch self {
        case .oneWeek:
            return calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .oneMonth:
            return calendar.date(byAdding: .month, value: -1, to: now) ?? .distantPast
        case .threeMonths:
            return calendar.date(byAdding: .month, value: -3, to: now) ?? .distantPast
        case .sixMonths:
            return calendar.date(byAdding: .month, value: -6, to: now) ?? .distantPast
        case .oneYear:
            return calendar.date(byAdding: .year, value: -1, to: now) ?? .distantPast
        case .all:
            return .distantPast
        }
    }

    /// Libellé du sélecteur, partagé par les deux cibles pour qu'une période
    /// ne s'appelle pas « 6 mois » ici et « Six mois » là.
    var label: String {
        switch self {
        case .oneWeek: return "1 semaine"
        case .oneMonth: return "1 mois"
        case .threeMonths: return "3 mois"
        case .sixMonths: return "6 mois"
        case .oneYear: return "1 an"
        case .all: return "Tout"
        }
    }

    /// Les seules périodes qui ont un sens sur l'iPhone. HealthKit n'y est lu
    /// que sur `HealthKitReaderLive.initialWindowDays` (180 jours) : proposer
    /// « 1 an » afficherait une courbe qui commence brutalement à mi-axe,
    /// impossible à distinguer d'un trou dans les données. Le Mac, lui, garde
    /// toutes les périodes — il possède l'historique depuis 2012.
    ///
    /// « 6 mois » est le cas limite retenu : exprimé en mois calendaires il
    /// remonte jusqu'à 184 jours selon le mois de départ, soit quatre jours
    /// au-delà de la fenêtre. L'amorce manquante est de l'ordre du jour, pas
    /// du mois — invisible à l'écran, contrairement aux 185 jours vides que
    /// laisserait « 1 an ».
    static let companionCases: [TrendPeriod] = [.oneWeek, .oneMonth, .threeMonths, .sixMonths]
}

@MainActor
final class TrendsViewModel: ObservableObject {
    @Published private(set) var restingHeartRate: [TrendPoint] = []
    @Published private(set) var weight: [TrendPoint] = []
    @Published private(set) var vo2Max: [TrendPoint] = []
    @Published private(set) var sleepHours: [TrendPoint] = []

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
        let start = period.startDate(now: now(), calendar: calendar)
        let end = now()

        restingHeartRate = try dailyAverage(type: "HKQuantityTypeIdentifierRestingHeartRate", from: start, to: end)
        weight = try dailyAverage(type: "HKQuantityTypeIdentifierBodyMass", from: start, to: end)
        vo2Max = try dailyAverage(type: "HKQuantityTypeIdentifierVO2Max", from: start, to: end)
        sleepHours = try nightlySleepHours(from: start, to: end)
    }

    private func dailyAverage(type: String, from: Date, to: Date) throws -> [TrendPoint] {
        let resolved = resolver.resolve(try store.records(type: type, from: from, to: to))
        let grouped = Dictionary(grouping: resolved) { calendar.startOfDay(for: $0.startDate) }
        return grouped
            .map { day, records in
                TrendPoint(date: day, value: records.reduce(0) { $0 + $1.value } / Double(records.count))
            }
            .sorted { $0.date < $1.date }
    }

    /// Moyenne mobile glissante sur `window` points — un point par position à
    /// partir de la première fenêtre complète, rien si la série est trop courte.
    nonisolated static func movingAverage(_ points: [TrendPoint], window: Int = 7) -> [TrendPoint] {
        guard window > 1, points.count >= window else { return [] }
        return (window - 1 ..< points.count).map { index in
            let slice = points[(index - window + 1)...index]
            let mean = slice.reduce(0) { $0 + $1.value } / Double(window)
            return TrendPoint(date: points[index].date, value: mean)
        }
    }

    private func nightlySleepHours(from: Date, to: Date) throws -> [TrendPoint] {
        let resolved = resolver.resolve(try store.sleepRecords(from: from, to: to))
        return SleepAggregator.nightlyHours(resolved, calendar: calendar)
    }
}
