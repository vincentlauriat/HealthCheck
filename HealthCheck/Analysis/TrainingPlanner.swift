import Foundation

/// Rôle d'une semaine dans la préparation.
enum WeekRole: Equatable {
    case currentWeekClosing  // semaine en cours trop entamée pour recevoir des cibles
    case build
    case peak                // course − 2
    case taper               // course − 1
    case raceWeek
}

/// Placeholder remplacé par la tâche 3, qui définit les séances.
struct PlannedSession: Equatable {}

struct PlannedWeek: Equatable {
    let monday: Date
    let role: WeekRole
    let targetKm: Double
    var sessions: [PlannedSession]
}

struct TrainingPlan: Equatable {
    let goal: RaceGoal
    let weeks: [PlannedWeek]
    let hrMax: Double
}

/// Construit un plan déterministe : mêmes entrées, même plan. Rien n'est
/// persisté — le plan est recalculé à chaque affichage, donc il ne peut
/// pas se désynchroniser de ce qui a réellement été couru.
enum TrainingPlanner {
    static let comebackRampFactor = 1.15
    static let steadyRampFactor = 1.10
    static let minimumStartVolumeKm = 10.0
    static let peakVolumeMultiplier = 1.5
    static let taperFactor = 0.75
    static let raceWeekFactor = 0.5
    static let fallbackPaceMinutesPerKm = 7.0
    static let minimumDaysForTargets = 3
    static let runningActivityType = "HKWorkoutActivityTypeRunning"

    // MARK: - Lectures de charge

    /// Distance d'une séance : la valeur réelle si elle existe, sinon une
    /// estimation à 7:00/km. Le même repli partout — deux définitions
    /// laisseraient le planificateur et le moniteur lire des charges
    /// différentes pour le même historique.
    static func distanceKm(_ workout: Workout) -> Double {
        if let d = workout.totalDistance { return d }
        return WorkoutStatsEngine.durationMinutes(workout) / fallbackPaceMinutesPerKm
    }

    static func acuteKm(history: [Workout], today: Date, calendar: Calendar) -> Double {
        sumKm(history, days: 7, endingOn: today, calendar: calendar)
    }

    static func chronicWeeklyKm(history: [Workout], today: Date, calendar: Calendar) -> Double {
        sumKm(history, days: 28, endingOn: today, calendar: calendar) / 4.0
    }

    private static func sumKm(_ history: [Workout], days: Int, endingOn today: Date,
                              calendar: Calendar) -> Double {
        let endExclusive = calendar.date(byAdding: .day, value: 1,
                                         to: calendar.startOfDay(for: today))!
        let start = calendar.date(byAdding: .day, value: -days, to: endExclusive)!
        return history
            .filter { $0.activityType == runningActivityType }
            .filter { $0.startDate >= start && $0.startDate < endExclusive }
            .reduce(0) { $0 + distanceKm($1) }
    }

    // MARK: - Dates

    static func monday(of date: Date, calendar: Calendar) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        let start = cal.startOfDay(for: date)
        let weekday = cal.component(.weekday, from: start)  // dimanche = 1
        let offset = (weekday + 5) % 7                       // lundi → 0, dimanche → 6
        return cal.date(byAdding: .day, value: -offset, to: start)!
    }

    /// Jours restants dans la semaine, aujourd'hui compris : lundi → 7,
    /// dimanche → 1.
    static func daysRemainingInWeek(from today: Date, calendar: Calendar) -> Int {
        var cal = calendar
        cal.firstWeekday = 2
        let weekday = cal.component(.weekday, from: cal.startOfDay(for: today))
        return 7 - ((weekday + 5) % 7)
    }

    // MARK: - Plan

    static func plan(goal: RaceGoal, history: [Workout], hrMax: Double,
                     today: Date, calendar: Calendar) -> TrainingPlan {
        let runs = history.filter { $0.activityType == runningActivityType }
        let currentMonday = monday(of: today, calendar: calendar)
        let raceMonday = monday(of: goal.raceDate, calendar: calendar)

        // La semaine en cours ne reçoit des cibles que s'il y reste assez
        // de jours pour les trois séances cœur ; sinon elle est affichée
        // telle quelle et la montée en charge démarre lundi prochain.
        let currentWeekTakesTargets =
            daysRemainingInWeek(from: today, calendar: calendar) >= minimumDaysForTargets
        let firstBuildMonday = currentWeekTakesTargets
            ? currentMonday
            : calendar.date(byAdding: .day, value: 7, to: currentMonday)!

        var mondays: [Date] = []
        var cursor = firstBuildMonday
        while cursor <= raceMonday {
            mondays.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 7, to: cursor)!
        }

        var weeks: [PlannedWeek] = []
        if !currentWeekTakesTargets {
            weeks.append(PlannedWeek(monday: currentMonday, role: .currentWeekClosing,
                                     targetKm: 0, sessions: []))
        }
        guard !mondays.isEmpty else {
            return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax)
        }

        let start = max(chronicWeeklyKm(history: runs, today: today, calendar: calendar),
                        acuteKm(history: runs, today: today, calendar: calendar),
                        minimumStartVolumeKm)
        let factor = start < goal.distanceKm ? comebackRampFactor : steadyRampFactor
        let volumeCap = goal.distanceKm * peakVolumeMultiplier

        // Deux semaines ou moins : trop tard pour progresser, on entretient.
        if mondays.count <= 2 {
            for (i, monday) in mondays.enumerated() {
                weeks.append(PlannedWeek(monday: monday,
                                         role: i == mondays.count - 1 ? .raceWeek : .taper,
                                         targetKm: start * taperFactor,
                                         sessions: []))
            }
            return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax)
        }

        // Le pic est à course − 2 ; on monte jusqu'à lui, puis on relâche.
        let peakIndex = mondays.count - 3
        var volume = start
        var peakVolume = start
        for (i, monday) in mondays.enumerated() {
            let role: WeekRole
            let target: Double
            if i <= peakIndex {
                volume = min(volume * factor, volumeCap)
                role = i == peakIndex ? .peak : .build
                target = volume
                if i == peakIndex { peakVolume = volume }
            } else if i == mondays.count - 1 {
                role = .raceWeek
                target = peakVolume * raceWeekFactor
            } else {
                role = .taper
                target = peakVolume * taperFactor
            }
            weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target, sessions: []))
        }
        return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax)
    }
}
