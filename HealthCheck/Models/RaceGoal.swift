import Foundation

/// Objectif de course : ce que l'utilisateur prépare. Contrairement à
/// `HealthRecord`/`Workout`, dont l'`id` est une clé de dédoublonnage
/// SHA256, un objectif n'a rien à dédoublonner — son `id` est un UUID
/// créé à la saisie, et le réenregistrer avec le même id le met à jour.
struct RaceGoal: Equatable {
    enum Objective: String, Equatable, CaseIterable {
        case finishComfortable   // seul objectif de la v1
    }

    let id: String
    let name: String
    let raceDate: Date
    let distanceKm: Double
    let elevationGainM: Double
    let objective: Objective
    let createdAt: Date

    /// Objectif actif : la course future la plus proche. Le jour de la
    /// course compte encore comme futur (comparaison au début du jour).
    static func active(in goals: [RaceGoal], today: Date,
                       calendar: Calendar = .current) -> RaceGoal? {
        let startOfToday = calendar.startOfDay(for: today)
        return goals
            .filter { calendar.startOfDay(for: $0.raceDate) >= startOfToday }
            .min { $0.raceDate < $1.raceDate }
    }
}
