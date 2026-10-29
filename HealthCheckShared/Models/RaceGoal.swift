import Foundation

/// Objectif de course : ce que l'utilisateur prépare. Contrairement à
/// `HealthRecord`/`Workout`, dont l'`id` est une clé de dédoublonnage
/// SHA256, un objectif n'a rien à dédoublonner — son `id` est un UUID
/// créé à la saisie, et le réenregistrer avec le même id le met à jour.
///
/// Une saison se compose d'une course **principale**, celle que le plan
/// prépare, et de courses de **préparation** qui s'insèrent dans ce plan
/// au lieu de le remplacer (spec 2026-10-29 season planning).
struct RaceGoal: Equatable {
    enum Objective: String, Equatable, CaseIterable {
        case finishComfortable   // seul objectif de la v1
    }

    /// Place de la course dans la saison.
    enum Priority: String, Equatable, CaseIterable {
        /// La course que tout le plan prépare : son affûtage, son pic.
        case main
        /// Une course sur le chemin : elle remplace la sortie longue de sa
        /// semaine, allège la semaine et, si elle est longue, est suivie
        /// d'une semaine de récupération. Elle ne réancre pas le plan.
        case tuneUp
    }

    let id: String
    let name: String
    let raceDate: Date
    let distanceKm: Double
    let elevationGainM: Double
    let objective: Objective
    let createdAt: Date
    let priority: Priority
    /// Plafond de volume hebdomadaire choisi par l'utilisateur. `nil` : le
    /// plafond est calculé (`TrainingPlanner.volumeCapKm`). Renseigné, il
    /// est appliqué tel quel, même très haut : le moteur conseille, il
    /// n'interdit pas — le moniteur de charge dit seulement ce qu'il en pense.
    let peakWeeklyKmOverride: Double?

    init(id: String, name: String, raceDate: Date, distanceKm: Double, elevationGainM: Double,
         objective: Objective, createdAt: Date, priority: Priority = .main,
         peakWeeklyKmOverride: Double? = nil) {
        self.id = id
        self.name = name
        self.raceDate = raceDate
        self.distanceKm = distanceKm
        self.elevationGainM = elevationGainM
        self.objective = objective
        self.createdAt = createdAt
        self.priority = priority
        self.peakWeeklyKmOverride = peakWeeklyKmOverride
    }

    /// La même course sans plafond personnalisé : ce que le calcul
    /// proposerait, pour comparer au choix de l'utilisateur.
    var withoutOverride: RaceGoal {
        RaceGoal(id: id, name: name, raceDate: raceDate, distanceKm: distanceKm,
                 elevationGainM: elevationGainM, objective: objective, createdAt: createdAt,
                 priority: priority, peakWeeklyKmOverride: nil)
    }

    /// Kilomètre-effort : la distance plus un kilomètre par tranche de
    /// 100 m de dénivelé positif — l'équivalence d'usage en trail. Un
    /// 17 km à 650 m D+ « pèse » 23,5 km.
    var effortKm: Double { distanceKm + elevationGainM / 100 }

    /// Parcours de trail : au moins 30 m de D+ par kilomètre. À ce
    /// gradient, la sortie longue doit elle-même porter du dénivelé.
    var isTrail: Bool {
        distanceKm > 0 && elevationGainM / distanceKm >= TrainingPlanner.trailGradientMPerKm
    }

    /// Objectif actif : la course **principale** future la plus proche.
    /// Sans course principale à venir, la course future la plus proche,
    /// quelle que soit sa priorité. Le jour de la course compte encore
    /// comme futur (comparaison au début du jour).
    static func active(in goals: [RaceGoal], today: Date,
                       calendar: Calendar = .current) -> RaceGoal? {
        let future = upcoming(in: goals, today: today, calendar: calendar)
        return future.first { $0.priority == .main } ?? future.first
    }

    /// Courses futures, la plus proche d'abord.
    static func upcoming(in goals: [RaceGoal], today: Date,
                         calendar: Calendar = .current) -> [RaceGoal] {
        let startOfToday = calendar.startOfDay(for: today)
        return goals
            .filter { calendar.startOfDay(for: $0.raceDate) >= startOfToday }
            .sorted { $0.raceDate < $1.raceDate }
    }

    /// Courses de préparation qui jalonnent le plan de `main` : priorité
    /// `.tuneUp`, avant la course principale. Les courses **passées** sont
    /// gardées : une semaine passée doit rester calculée comme elle l'a
    /// été, course comprise — sinon le plan changerait rétroactivement
    /// le lendemain de chaque course.
    static func tuneUps(for main: RaceGoal, in goals: [RaceGoal]) -> [RaceGoal] {
        goals
            .filter { $0.id != main.id && $0.priority == .tuneUp && $0.raceDate < main.raceDate }
            .sorted { $0.raceDate < $1.raceDate }
    }
}
