import Foundation

enum VO2MaxVerdict: Equatable {
    case rising
    case stable
    case declining
}

struct VO2MaxTrend: Equatable {
    let recentAverage: Double
    let priorAverage: Double
    let delta: Double
    let verdict: VO2MaxVerdict
}

struct VO2MaxStatus: Equatable {
    let trend: VO2MaxTrend?
    let alert: LoadAlert?
}

/// Interprète la VO2max comme un signal d'entraînement plutôt qu'une simple
/// courbe : tendance sur deux fenêtres glissantes (30 jours récents contre
/// 90 jours juste avant), et alerte quand elle stagne malgré une charge
/// soutenue. Comme tous les autres moteurs, pur et sans horloge propre.
enum VO2MaxEngine {
    static let vo2MaxType = "HKQuantityTypeIdentifierVO2Max"
    static let recentWindowDays = 30
    static let priorWindowDays = 90
    static let meaningfulDeltaThreshold = 1.0

    static func trend(records: [HealthRecord], today: Date, calendar: Calendar) -> VO2MaxTrend? {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        let recentStart = calendar.date(byAdding: .day, value: -recentWindowDays, to: endExclusive)!
        let priorStart = calendar.date(byAdding: .day, value: -(recentWindowDays + priorWindowDays),
                                       to: endExclusive)!

        let samples = records.filter { $0.type == vo2MaxType }
        let recentValues = samples
            .filter { $0.startDate >= recentStart && $0.startDate < endExclusive }
            .map(\.value)
        let priorValues = samples
            .filter { $0.startDate >= priorStart && $0.startDate < recentStart }
            .map(\.value)
        guard !recentValues.isEmpty, !priorValues.isEmpty else { return nil }

        let recentAverage = recentValues.reduce(0, +) / Double(recentValues.count)
        let priorAverage = priorValues.reduce(0, +) / Double(priorValues.count)
        let delta = recentAverage - priorAverage
        let verdict: VO2MaxVerdict
        if delta >= meaningfulDeltaThreshold {
            verdict = .rising
        } else if delta <= -meaningfulDeltaThreshold {
            verdict = .declining
        } else {
            verdict = .stable
        }
        return VO2MaxTrend(recentAverage: recentAverage, priorAverage: priorAverage,
                           delta: delta, verdict: verdict)
    }

    static func stagnationAlert(trend: VO2MaxTrend?, chronicKm: Double) -> LoadAlert? {
        guard let trend, trend.verdict != .rising else { return nil }
        guard chronicKm >= TrainingLoadMonitor.meaningfulChronicKm else { return nil }
        if trend.verdict == .declining {
            return LoadAlert(severity: .warning, message: "VO2max en baisse malgré une charge d'entraînement soutenue — signe possible de surentraînement ou de récupération insuffisante.")
        }
        return LoadAlert(severity: .info, message: "VO2max stable malgré une charge d'entraînement soutenue — un palier normal, ou un signal pour varier l'intensité.")
    }
}
