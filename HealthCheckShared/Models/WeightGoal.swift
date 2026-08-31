import Foundation

/// Objectif de poids : parallèle à RaceGoal, même sémantique de mise à jour
/// — l'id est un UUID créé à la saisie, le réenregistrer avec le même id
/// met à jour plutôt que dupliquer.
struct WeightGoal: Equatable {
    let id: String
    let targetWeightKg: Double
    let targetDate: Date
    let createdAt: Date

    /// Objectif actif : la date cible future la plus proche. Le jour cible
    /// compte encore comme futur (comparaison au début du jour) — même
    /// sémantique que RaceGoal.active.
    static func active(in goals: [WeightGoal], today: Date,
                       calendar: Calendar = .current) -> WeightGoal? {
        let startOfToday = calendar.startOfDay(for: today)
        return goals
            .filter { calendar.startOfDay(for: $0.targetDate) >= startOfToday }
            .min { $0.targetDate < $1.targetDate }
    }
}
