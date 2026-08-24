import Foundation

struct MatchedSession: Equatable {
    let session: PlannedSession
    let executed: Workout?
    let isDone: Bool
}

struct WeekProgress: Equatable {
    let matched: [MatchedSession]
    let offPlan: [Workout]
    let executedKm: Double
}

/// Rapproche les séances réellement courues des séances prévues. Rien
/// n'est persisté : le rapprochement est recalculé à chaque affichage,
/// donc il ne peut pas se désynchroniser de la réalité.
enum SessionMatcher {
    static let doneThreshold = 0.70

    static func match(week: PlannedWeek, executed: [Workout]) -> WeekProgress {
        let runs = executed.filter { $0.activityType == TrainingPlanner.runningActivityType }
        let executedKm = runs.reduce(0) { $0 + TrainingPlanner.distanceKm($1) }
        var pool = runs.sorted { TrainingPlanner.distanceKm($0) > TrainingPlanner.distanceKm($1) }

        var matched = Array<MatchedSession?>(repeating: nil, count: week.sessions.count)

        // D'abord les séances définies en distance, appariées par taille.
        let distanceIndexSessions = week.sessions.enumerated()
            .filter { $0.element.targetKm > 0 }
            .sorted { $0.element.targetKm > $1.element.targetKm }

        for (index, session) in distanceIndexSessions {
            let run = pool.isEmpty ? nil : pool.removeFirst()
            let done = run.map { TrainingPlanner.distanceKm($0) >= session.targetKm * doneThreshold } ?? false
            matched[index] = MatchedSession(session: session, executed: run, isDone: done)
        }

        // Les séances définies en durée ne prennent jamais un créneau dans
        // ce tri : elles se contentent d'une sortie restante s'il y en a une.
        let durationIndexSessions = week.sessions.enumerated()
            .filter { $0.element.targetKm <= 0 }

        for (index, session) in durationIndexSessions {
            let run = pool.isEmpty ? nil : pool.removeFirst()
            matched[index] = MatchedSession(session: session, executed: run, isDone: run != nil)
        }

        return WeekProgress(matched: matched.compactMap { $0 },
                            offPlan: pool, executedKm: executedKm)
    }
}
