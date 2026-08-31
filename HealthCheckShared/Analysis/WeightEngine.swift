import Foundation

enum WeightDirection: Equatable {
    case losing
    case gaining
    case stable
}

struct WeightTrend: Equatable {
    let recentAverageKg: Double
    let priorAverageKg: Double
    let weeklyRateKg: Double
    let direction: WeightDirection
}

enum TrajectoryVerdict: Equatable {
    case onTrack
    case tooSlow
    case tooFast
}

struct WeightTrajectory: Equatable {
    let verdict: TrajectoryVerdict
    let requiredWeeklyRateKg: Double
    let weeksRemaining: Double
}

/// Interprète le poids comme un signal d'entraînement/santé plutôt qu'une
/// simple courbe : tendance sur deux fenêtres glissantes (14 jours récents
/// contre 14 jours juste avant — même principe que VO2MaxEngine : des
/// moyennes de fenêtre, jamais un delta premier/dernier point, fragile aux
/// valeurs isolées), trajectoire vers un objectif optionnel, et alerte de
/// sécurité de rythme. Pur et sans horloge propre, comme tous les autres
/// moteurs.
enum WeightEngine {
    static let recentWindowDays = 14
    static let priorWindowDays = 14
    static let stableNoiseThresholdKg = 0.15
    static let onTrackToleranceRatio = 0.20
    static let safeWarningRatePercent = 1.0
    static let safeInfoRatePercent = 0.5

    static func trend(weights: [TrendPoint], today: Date, calendar: Calendar) -> WeightTrend? {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        let recentStart = calendar.date(byAdding: .day, value: -recentWindowDays, to: endExclusive)!
        let priorStart = calendar.date(byAdding: .day, value: -(recentWindowDays + priorWindowDays),
                                       to: endExclusive)!

        let recentValues = weights
            .filter { $0.date >= recentStart && $0.date < endExclusive }
            .map(\.value)
        let priorValues = weights
            .filter { $0.date >= priorStart && $0.date < recentStart }
            .map(\.value)
        guard !recentValues.isEmpty, !priorValues.isEmpty else { return nil }

        let recentAverage = recentValues.reduce(0, +) / Double(recentValues.count)
        let priorAverage = priorValues.reduce(0, +) / Double(priorValues.count)
        let delta = recentAverage - priorAverage
        let weeklyRate = delta / 2.0 // 2 semaines entre les centres des deux fenêtres
        let direction: WeightDirection = abs(delta) < stableNoiseThresholdKg
            ? .stable : (delta > 0 ? .gaining : .losing)

        return WeightTrend(recentAverageKg: recentAverage, priorAverageKg: priorAverage,
                           weeklyRateKg: weeklyRate, direction: direction)
    }

    static func trajectory(trend: WeightTrend?, goal: WeightGoal?, today: Date,
                           calendar: Calendar) -> WeightTrajectory? {
        guard let trend, let goal else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                           to: calendar.startOfDay(for: goal.targetDate)).day ?? 0
        guard days > 0 else { return nil }
        let weeksRemaining = Double(days) / 7.0
        let requiredWeeklyRate = (goal.targetWeightKg - trend.recentAverageKg) / weeksRemaining

        guard abs(requiredWeeklyRate) > 0.01 else {
            return WeightTrajectory(verdict: .onTrack, requiredWeeklyRateKg: requiredWeeklyRate,
                                    weeksRemaining: weeksRemaining)
        }
        // ratio < 0 (rythme réel de signe opposé au rythme requis) tombe
        // naturellement sous le plancher de tolérance -> .tooSlow, pas un
        // cas séparé : ne pas progresser vers l'objectif reste ne pas
        // progresser assez vite, que ce soit à l'arrêt ou à contresens.
        let ratio = trend.weeklyRateKg / requiredWeeklyRate
        let verdict: TrajectoryVerdict
        if ratio < 1 - onTrackToleranceRatio {
            verdict = .tooSlow
        } else if ratio > 1 + onTrackToleranceRatio {
            verdict = .tooFast
        } else {
            verdict = .onTrack
        }
        return WeightTrajectory(verdict: verdict, requiredWeeklyRateKg: requiredWeeklyRate,
                                weeksRemaining: weeksRemaining)
    }

    static func safetyAlert(trend: WeightTrend?, trainingLoadElevated: Bool) -> LoadAlert? {
        guard let trend, trend.recentAverageKg > 0 else { return nil }
        let ratePercent = abs(trend.weeklyRateKg) / trend.recentAverageKg * 100
        if ratePercent >= safeWarningRatePercent {
            let base = "Rythme de variation du poids au-dessus du repère usuel (≈1 %/semaine)."
            let message = trainingLoadElevated
                ? base + " Combiné à une charge d'entraînement élevée, veillez à un apport énergétique suffisant."
                : base
            return LoadAlert(severity: .warning, message: message)
        }
        if ratePercent >= safeInfoRatePercent {
            return LoadAlert(severity: .info, message: "Rythme de variation du poids notable — à surveiller.")
        }
        return nil
    }
}
