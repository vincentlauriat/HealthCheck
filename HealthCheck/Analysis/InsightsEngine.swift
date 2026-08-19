import Foundation

struct Insight: Equatable {
    enum Sentiment { case positive, neutral, warning }

    let systemImage: String
    let title: String
    let message: String
    let sentiment: Sentiment
}

/// Entrées pré-agrégées du moteur d'insights — le ViewModel fait les requêtes,
/// le moteur ne fait que du raisonnement pur (testable sans base).
struct InsightInputs {
    var restingHRMean7: Double?
    var restingHRMean30: Double?
    var sleepHoursMean7: Double?
    var stepsThisWeek: Double?
    var stepsLastWeek: Double?
    var vo2Latest: Double?
    var vo2ThreeMonthsAgo: Double?
    var weightDelta30d: Double?
}

/// Génère des observations en langage naturel à partir des agrégats.
/// Les alertes sortent en premier, puis les positives, puis les neutres.
enum InsightsEngine {
    static func generate(from inputs: InsightInputs) -> [Insight] {
        var insights: [Insight] = []

        if let mean7 = inputs.restingHRMean7, let mean30 = inputs.restingHRMean30, mean30 > 0 {
            let deltaPercent = (mean7 - mean30) / mean30 * 100
            if deltaPercent >= 3 {
                insights.append(Insight(
                    systemImage: "heart.fill",
                    title: "FC repos élevée",
                    message: "Votre fréquence cardiaque au repos est \(Int(deltaPercent.rounded())) % au-dessus de votre normale sur 7 jours — fatigue, stress ou récupération incomplète possibles.",
                    sentiment: .warning
                ))
            } else if deltaPercent <= -3 {
                insights.append(Insight(
                    systemImage: "heart.fill",
                    title: "FC repos en baisse",
                    message: "Votre fréquence cardiaque au repos est \(Int(abs(deltaPercent).rounded())) % sous votre normale — signe d'une bonne condition cardiovasculaire.",
                    sentiment: .positive
                ))
            }
        }

        if let sleep7 = inputs.sleepHoursMean7 {
            if sleep7 < 7 {
                insights.append(Insight(
                    systemImage: "moon.zzz.fill",
                    title: "Dette de sommeil",
                    message: String(format: "%.1f h de sommeil par nuit en moyenne cette semaine — en dessous des 7 h recommandées.", sleep7),
                    sentiment: .warning
                ))
            } else if sleep7 >= 7.5 {
                insights.append(Insight(
                    systemImage: "moon.zzz.fill",
                    title: "Sommeil solide",
                    message: String(format: "%.1f h par nuit en moyenne cette semaine — continuez comme ça.", sleep7),
                    sentiment: .positive
                ))
            }
        }

        if let thisWeek = inputs.stepsThisWeek, let lastWeek = inputs.stepsLastWeek, lastWeek > 0 {
            let deltaPercent = (thisWeek - lastWeek) / lastWeek * 100
            if deltaPercent >= 20 {
                insights.append(Insight(
                    systemImage: "figure.walk",
                    title: "Activité en hausse",
                    message: "\(Int(deltaPercent.rounded())) % de pas en plus que la semaine dernière.",
                    sentiment: .positive
                ))
            } else if deltaPercent <= -20 {
                insights.append(Insight(
                    systemImage: "figure.walk",
                    title: "Activité en baisse",
                    message: "\(Int(abs(deltaPercent).rounded())) % de pas en moins que la semaine dernière.",
                    sentiment: .neutral
                ))
            }
        }

        if let latest = inputs.vo2Latest, let older = inputs.vo2ThreeMonthsAgo, latest - older >= 1 {
            insights.append(Insight(
                systemImage: "lungs.fill",
                title: "VO₂ max en progression",
                message: String(format: "%.1f → %.1f ml/kg/min sur les trois derniers mois — votre capacité aérobie s'améliore.", older, latest),
                sentiment: .positive
            ))
        }

        if let weightDelta = inputs.weightDelta30d, abs(weightDelta) >= 1 {
            let direction = weightDelta > 0 ? "pris" : "perdu"
            insights.append(Insight(
                systemImage: "scalemass.fill",
                title: "Évolution du poids",
                message: String(format: "Vous avez %@ %.1f kg sur les 30 derniers jours.", direction, abs(weightDelta)),
                sentiment: .neutral
            ))
        }

        let order: [Insight.Sentiment: Int] = [.warning: 0, .positive: 1, .neutral: 2]
        return insights.sorted { (order[$0.sentiment] ?? 3) < (order[$1.sentiment] ?? 3) }
    }
}
