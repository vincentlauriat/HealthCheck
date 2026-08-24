import Foundation

struct LoadAlert: Equatable {
    enum Severity: Equatable { case info, warning }
    let severity: Severity
    let message: String
}

struct LoadAssessment: Equatable {
    let acuteKm: Double
    let chronicWeeklyKm: Double
    let acwr: Double?          // nil tant que l'historique ne le rend pas signifiant
    let alerts: [LoadAlert]
}

/// Surveillance de la charge, en deux régimes. Avec un plan actif, les
/// alertes comparent le réalisé à la cible du plan : une montée conforme
/// au plan est sûre par construction (le planificateur plafonne déjà la
/// progression), et le ratio brut ne doit pas la contredire — une reprise
/// affiche mécaniquement un ratio énorme. Sans plan, le ratio
/// aigu/chronique pilote les alertes.
enum TrainingLoadMonitor {
    static let highRatio = 1.3
    static let lowRatio = 0.8
    static let meaningfulChronicKm = 8.0
    static let minimumActiveWeeks = 3
    static let overshootFactor = 1.25
    static let behindFactor = 0.5
    static let lateWeekDaysLeft = 2
    static let lowReadinessScore = 50.0

    static func assess(history: [Workout], plan: TrainingPlan?, readiness: ReadinessScore?,
                       today: Date, calendar: Calendar) -> LoadAssessment {
        let runs = history.filter { $0.activityType == TrainingPlanner.runningActivityType }
        let acute = TrainingPlanner.acuteKm(history: runs, today: today, calendar: calendar)
        let chronic = TrainingPlanner.chronicWeeklyKm(history: runs, today: today, calendar: calendar)

        let meaningful = weeksWithARun(runs, today: today, calendar: calendar) >= minimumActiveWeeks
            || chronic >= meaningfulChronicKm
        let acwr = (meaningful && chronic > 0) ? acute / chronic : nil

        var alerts: [LoadAlert] = []
        if !meaningful {
            alerts.append(LoadAlert(severity: .info,
                message: "Reprise en cours — l'indicateur de charge s'activera après 3 semaines régulières."))
        }

        if let plan,
           let week = plan.weeks.first(where: { $0.monday == TrainingPlanner.monday(of: today, calendar: calendar) }),
           week.role != .currentWeekClosing {
            let progress = SessionMatcher.match(week: week,
                executed: runsOfWeek(runs, monday: week.monday, calendar: calendar))
            if progress.executedKm > week.targetKm * overshootFactor {
                alerts.append(LoadAlert(severity: .warning,
                    message: "Vous dépassez le plan — tenez-vous-en aux séances prévues."))
            } else if progress.executedKm < week.targetKm * behindFactor,
                      TrainingPlanner.daysRemainingInWeek(from: today, calendar: calendar) <= lateWeekDaysLeft {
                alerts.append(LoadAlert(severity: .info,
                    message: "Semaine en retard — elle ne sera pas rattrapée la semaine suivante."))
            }
            if let readiness, readiness.value < lowReadinessScore,
               progress.matched.contains(where: {
                   !$0.isDone && ($0.session.kind == .longRun || $0.session.kind == .hills)
               }) {
                alerts.append(LoadAlert(severity: .info,
                    message: "Forme du jour basse — intervertissez avec une séance facile."))
            }
        } else if plan == nil, let acwr {
            if acwr > highRatio {
                alerts.append(LoadAlert(severity: .warning,
                    message: "Vous progressez trop vite — réduisez cette semaine."))
            } else if acwr < lowRatio {
                alerts.append(LoadAlert(severity: .info,
                    message: "Vous pouvez en faire un peu plus."))
            }
        }

        return LoadAssessment(acuteKm: acute, chronicWeeklyKm: chronic, acwr: acwr, alerts: alerts)
    }

    /// Nombre de semaines distinctes contenant au moins une sortie sur les
    /// 28 derniers jours — le vrai signal de « historique établi », qu'un
    /// simple volume ne donne pas (une grosse sortie unique ne fait pas
    /// une base).
    static func weeksWithARun(_ runs: [Workout], today: Date, calendar: Calendar) -> Int {
        let start = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: today))!
        return Set(runs.filter { $0.startDate >= start }
                       .map { TrainingPlanner.monday(of: $0.startDate, calendar: calendar) }).count
    }

    static func runsOfWeek(_ runs: [Workout], monday: Date, calendar: Calendar) -> [Workout] {
        let end = calendar.date(byAdding: .day, value: 7, to: monday)!
        return runs.filter { $0.startDate >= monday && $0.startDate < end }
    }
}
