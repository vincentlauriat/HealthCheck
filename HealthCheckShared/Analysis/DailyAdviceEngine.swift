import Foundation

enum AdviceTier: Equatable {
    case repos
    case prudence
    case opportunite
}

struct DailyAdvice: Equatable {
    let tier: AdviceTier
    let message: String
}

/// Compose un conseil du jour unique à partir de verdicts déjà calculés par
/// d'autres moteurs (HealthScoreEngine, TrainingLoadMonitor, VO2MaxEngine).
/// Ne recalcule jamais rien lui-même et n'introduit aucun nouveau seuil —
/// le palier est directement le label de HealthScoreEngine.label(for:).
enum DailyAdviceEngine {
    static func advise(
        readiness: ReadinessScore?,
        loadAlerts: [LoadAlert],
        vo2MaxAlert: LoadAlert?
    ) -> DailyAdvice? {
        guard let readiness else { return nil }
        let tier = Self.tier(for: readiness.label)

        // Une alerte .warning ne peut affiner le conseil que sous REPOS ou
        // PRUDENCE — jamais sous OPPORTUNITÉ, où elle contredirait le label
        // déjà affiché. Ordre de scan fixe et déterministe : les alertes de
        // charge d'abord (dans leur ordre de production), puis celle de
        // VO2max.
        if tier != .opportunite,
           let warning = (loadAlerts + [vo2MaxAlert].compactMap { $0 })
               .first(where: { $0.severity == .warning }) {
            return DailyAdvice(tier: tier, message: warning.message)
        }

        return DailyAdvice(tier: tier, message: Self.genericMessage(for: tier))
    }

    // Couplé aux libellés exacts de HealthScoreEngine.label(for:) — si ces
    // libellés changent, ce switch doit changer avec. Un libellé inconnu
    // bascule vers .prudence (palier neutre, qui autorise toujours la
    // substitution d'alerte) plutôt que vers .opportunite : un `default`
    // optimiste masquerait silencieusement une vraie alerte .warning.
    private static func tier(for label: String) -> AdviceTier {
        switch label {
        case "Récupération conseillée": return .repos
        case "Forme correcte": return .prudence
        case "Bonne forme", "Excellente forme": return .opportunite
        default: return .prudence
        }
    }

    private static func genericMessage(for tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance."
        case .prudence: return "Restez sur des séances modérées aujourd'hui — ce n'est pas le jour pour repousser vos limites."
        case .opportunite: return "Vous êtes en forme — bon moment pour une séance clé."
        }
    }
}
