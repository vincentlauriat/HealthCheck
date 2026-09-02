import Foundation

/// Corrélation prête à afficher : question en français, axes, résultat.
struct CorrelationCard: Equatable {
    let question: String
    let xLabel: String
    let yLabel: String
    let result: CorrelationResult?
    /// Lecture en français du signe et de la force, ou explication de
    /// l'absence de résultat.
    let reading: String
}

@MainActor
final class CorrelationsViewModel: ObservableObject {
    @Published private(set) var cards: [CorrelationCard] = []

    /// Fenêtre d'analyse : assez longue pour avoir ≥ 10 paires malgré les
    /// nuits non trackées, assez courte pour rester « toi, récemment ».
    static let windowDays = 180

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
        guard let start = calendar.date(byAdding: .day, value: -Self.windowDays, to: end) else { return }

        let sleep = SleepAggregator.nightlyHours(resolver.resolve(try store.sleepRecords(from: start, to: end)), calendar: calendar)
        let restingHR = try dailyAverage("HKQuantityTypeIdentifierRestingHeartRate", from: start, to: end)
        let hrv = try dailyAverage("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", from: start, to: end)
        let energy = try dailyTotal("HKQuantityTypeIdentifierActiveEnergyBurned", from: start, to: end)
        let weight = try dailyAverage("HKQuantityTypeIdentifierBodyMass", from: start, to: end)
        let energy7d = TrendsViewModel.movingAverage(energy, window: 7)

        // La nuit étiquetée jour D commence le soir du jour D : la FC repos et
        // la HRV qu'elle influence sont mesurées le jour D+1.
        cards = [
            card(
                question: "Mieux dormir fait-il baisser ta FC repos du lendemain ?",
                x: sleep, xLabel: "Sommeil (h)",
                y: restingHR, yLabel: "FC repos J+1 (bpm)",
                lag: 1, expectation: .negative
            ),
            card(
                question: "Mieux dormir améliore-t-il ta HRV du lendemain ?",
                x: sleep, xLabel: "Sommeil (h)",
                y: hrv, yLabel: "HRV J+1 (ms)",
                lag: 1, expectation: .positive
            ),
            card(
                question: "Bouger plus fait-il mieux dormir la nuit suivante ?",
                x: energy, xLabel: "Calories actives (kcal)",
                y: sleep, yLabel: "Sommeil de la nuit (h)",
                lag: 0, expectation: .positive
            ),
            card(
                question: "L'effort de la veille pèse-t-il sur ta FC repos ?",
                x: energy, xLabel: "Calories actives (kcal)",
                y: restingHR, yLabel: "FC repos J+1 (bpm)",
                lag: 1, expectation: .none
            ),
            card(
                question: "Ton activité (moyenne 7 j) suit-elle ton poids ?",
                x: energy7d, xLabel: "Calories actives, moy. 7 j (kcal)",
                y: weight, yLabel: "Poids (kg)",
                lag: 0, expectation: .none
            )
        ]
    }

    private enum Expectation { case positive, negative, none }

    private func card(
        question: String,
        x: [TrendPoint], xLabel: String,
        y: [TrendPoint], yLabel: String,
        lag: Int, expectation: Expectation
    ) -> CorrelationCard {
        guard let result = CorrelationEngine.correlate(x: x, y: y, lagDays: lag, calendar: calendar) else {
            return CorrelationCard(
                question: question, xLabel: xLabel, yLabel: yLabel, result: nil,
                reading: "Pas assez de jours où les deux mesures existent (minimum \(CorrelationEngine.minimumPairs))."
            )
        }
        let strength = CorrelationEngine.strengthLabel(result.r)
        let direction = result.r >= 0 ? "positive" : "négative"
        var reading = "Corrélation \(direction) \(strength) (r = \(result.r.formatted(.number.precision(.fractionLength(2)))), \(result.points.count) jours)."
        if strength == "négligeable" {
            reading = "Aucun lien mesurable sur \(result.points.count) jours (r = \(result.r.formatted(.number.precision(.fractionLength(2)))))."
        } else {
            switch expectation {
            case .positive where result.r > 0, .negative where result.r < 0:
                reading += " C'est le sens physiologiquement attendu."
            default:
                break
            }
        }
        return CorrelationCard(question: question, xLabel: xLabel, yLabel: yLabel, result: result, reading: reading)
    }

    private func dailyAverage(_ type: String, from: Date, to: Date) throws -> [TrendPoint] {
        DailyAggregator.averages(resolver.resolve(try store.records(type: type, from: from, to: to)), calendar: calendar)
    }

    private func dailyTotal(_ type: String, from: Date, to: Date) throws -> [TrendPoint] {
        DailyAggregator.totals(resolver.resolve(try store.records(type: type, from: from, to: to)), calendar: calendar)
    }
}
