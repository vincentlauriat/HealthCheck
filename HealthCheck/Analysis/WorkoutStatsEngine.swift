import Foundation

/// Volume hebdomadaire d'entraînement, ventilé par activité.
struct WeekVolume: Equatable {
    let weekStart: Date
    /// Minutes par libellé d'activité (français).
    let minutesByActivity: [String: Double]

    var totalMinutes: Double { minutesByActivity.values.reduce(0, +) }
}

enum WorkoutStatsEngine {
    /// Libellés français des types HealthKit rencontrés dans les exports.
    /// Repli : identifiant sans son préfixe, pour ne jamais afficher du bruit.
    private static let labels: [String: String] = [
        "HKWorkoutActivityTypeWalking": "Marche",
        "HKWorkoutActivityTypeRunning": "Course",
        "HKWorkoutActivityTypeHiking": "Randonnée",
        "HKWorkoutActivityTypeCycling": "Vélo",
        "HKWorkoutActivityTypeSwimming": "Natation",
        "HKWorkoutActivityTypeHighIntensityIntervalTraining": "HIIT",
        "HKWorkoutActivityTypeFunctionalStrengthTraining": "Renfo fonctionnel",
        "HKWorkoutActivityTypeTraditionalStrengthTraining": "Musculation",
        "HKWorkoutActivityTypeRowing": "Rameur",
        "HKWorkoutActivityTypeMixedCardio": "Cardio mixte",
        "HKWorkoutActivityTypeUnderwaterDiving": "Plongée",
        "HKWorkoutActivityTypeSnowSports": "Sports d'hiver",
        "HKWorkoutActivityTypeElliptical": "Elliptique",
        "HKWorkoutActivityTypeYoga": "Yoga",
        "HKWorkoutActivityTypeCoreTraining": "Gainage",
        "HKWorkoutActivityTypeCooldown": "Récupération",
        "HKWorkoutActivityTypeStairClimbing": "Escaliers",
        "HKWorkoutActivityTypeTennis": "Tennis",
        "HKWorkoutActivityTypeSoccer": "Football",
        "HKWorkoutActivityTypeOther": "Autre"
    ]

    private static let icons: [String: String] = [
        "Marche": "figure.walk",
        "Course": "figure.run",
        "Randonnée": "figure.hiking",
        "Vélo": "figure.outdoor.cycle",
        "Natation": "figure.pool.swim",
        "HIIT": "bolt.fill",
        "Renfo fonctionnel": "figure.cross.training",
        "Musculation": "dumbbell.fill",
        "Rameur": "figure.rower",
        "Cardio mixte": "figure.mixed.cardio",
        "Plongée": "water.waves",
        "Sports d'hiver": "snowflake",
        "Elliptique": "figure.elliptical",
        "Yoga": "figure.yoga",
        "Gainage": "figure.core.training",
        "Récupération": "wind",
        "Escaliers": "figure.stairs",
        "Tennis": "tennis.racket",
        "Football": "soccerball"
    ]

    static func label(for activityType: String) -> String {
        labels[activityType] ?? activityType.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
    }

    static func icon(for label: String) -> String {
        icons[label] ?? "figure.mixed.cardio"
    }

    /// Durée en minutes quelle que soit l'unité stockée dans l'export.
    static func durationMinutes(_ workout: Workout) -> Double {
        switch workout.durationUnit {
        case "min": return workout.duration
        case "s", "sec": return workout.duration / 60
        case "hr", "h": return workout.duration * 60
        default: return workout.duration
        }
    }

    /// Volume par semaine calendaire, ventilé par activité, semaines vides
    /// incluses pour que le graphique ne saute pas de colonnes.
    static func weeklyVolumes(_ workouts: [Workout], weeks: Int, now: Date, calendar: Calendar) -> [WeekVolume] {
        guard weeks > 0,
              let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let starts = (0..<weeks).compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: currentWeekStart) }.reversed()

        let grouped = Dictionary(grouping: workouts) { workout in
            calendar.dateInterval(of: .weekOfYear, for: workout.startDate)?.start ?? workout.startDate
        }
        return starts.map { weekStart in
            let byActivity = Dictionary(grouping: grouped[weekStart] ?? []) { label(for: $0.activityType) }
                .mapValues { $0.reduce(0) { $0 + durationMinutes($1) } }
            return WeekVolume(weekStart: weekStart, minutesByActivity: byActivity)
        }
    }
}
