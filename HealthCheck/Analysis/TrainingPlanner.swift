import Foundation

/// Rôle d'une semaine dans la préparation.
enum WeekRole: Equatable {
    case currentWeekClosing  // semaine en cours trop entamée pour recevoir des cibles
    case build
    case peak                // course − 2
    case taper               // course − 1
    case raceWeek
}

enum SessionKind: Equatable {
    case longRun
    case hills
    case baseEndurance
    case optionalEasy
    case legOpener
}

struct PlannedSession: Equatable {
    let kind: SessionKind
    let targetKm: Double            // 0 pour les séances définies en durée
    let targetMinutes: Double?      // renseigné pour optionalEasy / legOpener
    let targetClimbM: Double        // consigne seulement — jamais vérifiée (spec §6.1)
    let hrRange: ClosedRange<Double>
    let note: String

    var isOptional: Bool { kind == .optionalEasy }
}

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
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)  // dimanche = 1
        // .weekday numbering (Sun=1…Sat=7) is independent of firstWeekday.
        let offset = (weekday + 5) % 7                       // lundi → 0, dimanche → 6
        return calendar.date(byAdding: .day, value: -offset, to: start)!
    }

    /// Jours restants dans la semaine, aujourd'hui compris : lundi → 7,
    /// dimanche → 1.
    static func daysRemainingInWeek(from today: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: calendar.startOfDay(for: today))
        // .weekday numbering (Sun=1…Sat=7) is independent of firstWeekday.
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

        var previousLong = longestRecentRunKm(history: runs, today: today, calendar: calendar)
        let peakClimb = min(maximumClimbM, goal.elevationGainM * 0.75)

        // Deux semaines ou moins : trop tard pour progresser, on entretient.
        if mondays.count <= 2 {
            for (i, monday) in mondays.enumerated() {
                let role: WeekRole = i == mondays.count - 1 ? .raceWeek : .taper
                let target = start * taperFactor
                let climb: Double = role == .raceWeek ? 0 : peakClimb * 0.5
                let weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                            climbTargetM: climb, goal: goal, hrMax: hrMax)
                if let long = weekSessions.first(where: { $0.kind == .longRun }) { previousLong = long.targetKm }
                weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target, sessions: weekSessions))
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
            let climb: Double
            switch role {
            case .peak:      climb = peakClimb
            case .build:     climb = firstWeekClimbM
                                    + (peakClimb - firstWeekClimbM) * Double(i) / Double(max(peakIndex, 1))
            case .taper:     climb = peakClimb * 0.5
            default:         climb = 0
            }
            let weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                        climbTargetM: climb, goal: goal, hrMax: hrMax)
            if let long = weekSessions.first(where: { $0.kind == .longRun }) { previousLong = long.targetKm }
            weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target, sessions: weekSessions))
        }
        return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax)
    }
}

extension TrainingPlanner {
    static let longRunShare = 0.60
    static let hillsShare = 0.25
    static let longRunWeeklyGrowthKm = 2.5
    static let minimumBaseKm = 3.0
    static let defaultPreviousLongKm = 5.0
    static let firstWeekClimbM = 100.0
    static let maximumClimbM = 300.0

    static func hrRange(_ low: Double, _ high: Double, hrMax: Double) -> ClosedRange<Double> {
        (hrMax * low)...(hrMax * high)
    }

    static func longestRecentRunKm(history: [Workout], today: Date, calendar: Calendar) -> Double {
        let start = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: today))!
        let recent = history
            .filter { $0.activityType == runningActivityType && $0.startDate >= start }
            .map(distanceKm)
        return recent.max() ?? defaultPreviousLongKm
    }

    static func sessions(role: WeekRole, targetKm: Double, previousLongKm: Double,
                         climbTargetM: Double, goal: RaceGoal, hrMax: Double) -> [PlannedSession] {
        let isTaper = role == .taper || role == .raceWeek
        var longKm = min(targetKm * longRunShare,
                         previousLongKm + longRunWeeklyGrowthKm,
                         min(14.0, goal.distanceKm * 0.8))
        if isTaper { longKm = min(longKm, goal.distanceKm * 0.4) }

        let easy = hrRange(0.60, 0.75, hrMax: hrMax)
        let endurance = hrRange(0.70, 0.80, hrMax: hrMax)
        let hard = hrRange(0.85, 0.92, hrMax: hrMax)

        var result = [
            PlannedSession(kind: .longRun, targetKm: longKm, targetMinutes: nil,
                           targetClimbM: 0, hrRange: isTaper ? easy : endurance,
                           note: isTaper
                               ? "Sortie longue allégée — restez très à l'aise."
                               : "Sortie longue : la séance qui construit votre distance. Allure conversation.")
        ]

        if role == .raceWeek {
            result.append(PlannedSession(kind: .legOpener, targetKm: 0, targetMinutes: 15,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Déverrouillage : 15 min souples avec deux ou trois accélérations courtes."))
        } else {
            result.append(PlannedSession(kind: .hills, targetKm: targetKm * hillsShare,
                                         targetMinutes: nil, targetClimbM: climbTargetM,
                                         hrRange: isTaper ? endurance : hard,
                                         note: "Parcours vallonné, visez environ \(Int(climbTargetM.rounded())) m de dénivelé positif."))
        }

        let used = result.reduce(0) { $0 + $1.targetKm }
        result.append(PlannedSession(kind: .baseEndurance,
                                     targetKm: max(targetKm - used, minimumBaseKm),
                                     targetMinutes: nil, targetClimbM: 0, hrRange: easy,
                                     note: "Endurance fondamentale : facile, vraiment facile."))

        if !isTaper {
            result.append(PlannedSession(kind: .optionalEasy, targetKm: 0, targetMinutes: 30,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Optionnelle : 30 min faciles, seulement si les trois autres séances sont faites et que vous vous sentez bien."))
        }
        return result
    }
}
