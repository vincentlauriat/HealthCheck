import Foundation

/// Paire de valeurs journalières alignées pour un nuage de points.
struct PairedPoint: Equatable {
    let day: Date
    let x: Double
    let y: Double
}

/// Résultat d'une corrélation : nil quand les données sont insuffisantes
/// pour dire quoi que ce soit d'honnête.
struct CorrelationResult: Equatable {
    let r: Double
    let points: [PairedPoint]
}

enum CorrelationEngine {
    /// En dessous de ce nombre de paires, un coefficient de Pearson est du
    /// bruit — on n'affiche rien plutôt qu'une fausse certitude.
    static let minimumPairs = 10

    /// Coefficient de Pearson. nil si trop peu de paires ou variance nulle
    /// (série constante : la corrélation n'est pas définie).
    static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        let n = Double(pairs.count)
        guard pairs.count >= minimumPairs else { return nil }
        let meanX = pairs.reduce(0) { $0 + $1.0 } / n
        let meanY = pairs.reduce(0) { $0 + $1.1 } / n
        var covariance = 0.0, varX = 0.0, varY = 0.0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varX += (x - meanX) * (x - meanX)
            varY += (y - meanY) * (y - meanY)
        }
        guard varX > 0, varY > 0 else { return nil }
        return covariance / (varX * varY).squareRoot()
    }

    /// Aligne deux séries journalières : la valeur de `x` au jour D est
    /// appariée à la valeur de `y` au jour D + `lagDays`. Seuls les jours où
    /// les deux existent produisent une paire.
    static func align(x: [TrendPoint], y: [TrendPoint], lagDays: Int, calendar: Calendar) -> [PairedPoint] {
        let yByDay = Dictionary(uniqueKeysWithValues: y.map { ($0.date, $0.value) })
        return x.compactMap { point in
            guard let laggedDay = calendar.date(byAdding: .day, value: lagDays, to: point.date),
                  let yValue = yByDay[laggedDay]
            else { return nil }
            return PairedPoint(day: point.date, x: point.value, y: yValue)
        }
    }

    /// Corrélation entre deux séries journalières avec décalage.
    static func correlate(x: [TrendPoint], y: [TrendPoint], lagDays: Int, calendar: Calendar) -> CorrelationResult? {
        let points = align(x: x, y: y, lagDays: lagDays, calendar: calendar)
        guard let r = pearson(points.map { ($0.x, $0.y) }) else { return nil }
        return CorrelationResult(r: r, points: points)
    }

    /// Qualification prudente de |r|, seuils usuels en physiologie.
    static func strengthLabel(_ r: Double) -> String {
        switch abs(r) {
        case 0.6...: return "forte"
        case 0.4..<0.6: return "modérée"
        case 0.2..<0.4: return "faible"
        default: return "négligeable"
        }
    }
}
