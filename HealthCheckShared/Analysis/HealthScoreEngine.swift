import Foundation

struct ScoreComponent: Equatable {
    let name: String
    let systemImage: String
    let score: Double // 0...100
    let detail: String
}

struct ReadinessScore: Equatable {
    let value: Double // 0...100, moyenne pondérée des composantes disponibles
    let label: String
    let components: [ScoreComponent]
}

/// Score de forme quotidien façon « recovery » : chaque composante compare la
/// valeur du jour à la baseline personnelle (fenêtre glissante ~30 jours) et
/// produit un score 0-100. Le score global est la moyenne pondérée des
/// composantes disponibles — une métrique absente réduit le panier, elle ne
/// pénalise pas.
enum HealthScoreEngine {
    static let minimumBaselineCount = 5

    /// FC repos : en dessous de sa normale = bon signe, au-dessus = fatigue.
    /// +5 % au-dessus de la baseline → 70 ; +10 % → 40.
    static func restingHeartRateScore(today: Double, baseline: [Double]) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, today > 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let deviation = (today - mean) / mean
        let score = (100 - deviation * 600).clamped(to: 0...100)
        return ScoreComponent(
            name: "FC repos",
            systemImage: "heart.fill",
            score: score,
            detail: "\(Int(today.rounded())) bpm · normale \(Int(mean.rounded()))"
        )
    }

    /// HRV (SDNN) : au-dessus de sa normale = bonne récupération.
    /// −10 % sous la baseline → 70.
    static func hrvScore(today: Double, baseline: [Double]) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, today > 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let deviation = (today - mean) / mean
        let score = (100 + deviation * 300).clamped(to: 0...100)
        return ScoreComponent(
            name: "Variabilité cardiaque",
            systemImage: "waveform.path.ecg",
            score: score,
            detail: "\(Int(today.rounded())) ms · normale \(Int(mean.rounded()))"
        )
    }

    /// Sommeil : la nuit dernière rapportée à la durée habituelle.
    /// Nuit complète (≥ baseline) → 100 ; 80 % de la baseline → 80.
    static func sleepScore(lastNightHours: Double, baseline: [Double]) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, lastNightHours > 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let ratio = lastNightHours / mean
        let score = (ratio * 100).clamped(to: 0...100)
        return ScoreComponent(
            name: "Sommeil",
            systemImage: "moon.zzz.fill",
            score: score,
            detail: String(format: "%.1f h · habituel %.1f h", lastNightHours, mean)
        )
    }

    /// Équilibre d'activité : la veille comparée à l'habitude — l'inactivité
    /// comme l'excès s'écartent de l'équilibre. ±25 % → 70.
    static func activityBalanceScore(yesterday: Double, baseline: [Double]) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, yesterday >= 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let deviation = abs((yesterday - mean) / mean)
        let score = (100 - deviation * 120).clamped(to: 0...100)
        return ScoreComponent(
            name: "Équilibre d'activité",
            systemImage: "flame.fill",
            score: score,
            detail: "\(Int(yesterday.rounded())) kcal hier · habituel \(Int(mean.rounded()))"
        )
    }

    /// Agrège les composantes disponibles en score global pondéré.
    /// Poids : sommeil 0,35 · FC repos 0,30 · HRV 0,25 · activité 0,10
    /// (renormalisés sur les composantes réellement présentes).
    static func readiness(
        sleep: ScoreComponent?,
        restingHeartRate: ScoreComponent?,
        hrv: ScoreComponent?,
        activity: ScoreComponent?
    ) -> ReadinessScore? {
        let weighted: [(ScoreComponent, Double)] = [
            (sleep, 0.35), (restingHeartRate, 0.30), (hrv, 0.25), (activity, 0.10)
        ].compactMap { component, weight in component.map { ($0, weight) } }

        guard !weighted.isEmpty else { return nil }

        let totalWeight = weighted.reduce(0) { $0 + $1.1 }
        let value = weighted.reduce(0) { $0 + $1.0.score * $1.1 } / totalWeight

        return ReadinessScore(value: value, label: label(for: value), components: weighted.map(\.0))
    }

    static func label(for score: Double) -> String {
        switch score {
        case 85...: return "Excellente forme"
        case 70..<85: return "Bonne forme"
        case 50..<70: return "Forme correcte"
        default: return "Récupération conseillée"
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
