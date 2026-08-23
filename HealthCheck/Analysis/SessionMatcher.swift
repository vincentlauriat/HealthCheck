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

        var byKind: [SessionKind: MatchedSession] = [:]

        // D'abord les séances définies en distance, appariées par taille.
        for session in week.sessions.filter({ $0.targetKm > 0 }).sorted(by: { $0.targetKm > $1.targetKm }) {
            let run = pool.isEmpty ? nil : pool.removeFirst()
            let done = run.map { TrainingPlanner.distanceKm($0) >= session.targetKm * doneThreshold } ?? false
            byKind[session.kind] = MatchedSession(session: session, executed: run, isDone: done)
        }
        // Les séances définies en durée ne prennent jamais un créneau dans
        // ce tri : elles se contentent d'une sortie restante s'il y en a une.
        for session in week.sessions where session.targetKm == 0 {
            let run = pool.isEmpty ? nil : pool.removeFirst()
            byKind[session.kind] = MatchedSession(session: session, executed: run, isDone: run != nil)
        }

        return WeekProgress(matched: week.sessions.compactMap { byKind[$0.kind] },
                            offPlan: pool, executedKm: executedKm)
    }
}
