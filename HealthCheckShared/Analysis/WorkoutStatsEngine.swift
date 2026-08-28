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
    /// `nil` pour une unité non reconnue — ne jamais inventer un nombre à
    /// partir d'une unité qu'on ne comprend pas. Chaque appelant décide
    /// explicitement de ce que « pas de durée exploitable » signifie pour
    /// lui, plutôt que de recevoir une valeur en minutes fabriquée en
    /// silence à partir d'une unité inconnue.
    static func durationMinutes(_ workout: Workout) -> Double? {
        switch workout.durationUnit {
        case "min": return workout.duration
        case "s", "sec": return workout.duration / 60
        case "hr", "h": return workout.duration * 60
        default: return nil
        }
    }

    /// Volume par semaine, ventilé par activité, semaines vides incluses
    /// pour que le graphique ne saute pas de colonnes.
    ///
    /// La semaine est ancrée au lundi via `TrainingPlanner.monday`, la même
    /// définition que celle utilisée par les moteurs d'entraînement — pas
    /// `calendar.dateInterval(of: .weekOfYear, for:)`, qui suit le
    /// `firstWeekday` de la locale et découperait donc les semaines
    /// différemment sur un appareil réglé en anglais américain. Une seule
    /// définition de « semaine » dans tout le projet.
    static func weeklyVolumes(_ workouts: [Workout], weeks: Int, now: Date, calendar: Calendar) -> [WeekVolume] {
        guard weeks > 0 else { return [] }
        let currentWeekStart = TrainingPlanner.monday(of: now, calendar: calendar)
        // -7 jours par pas, pas `.weekOfYear` : les clés du dictionnaire
        // ci-dessous viennent de `TrainingPlanner.monday` (jours), donc les
        // lundis générés ici doivent venir du même calcul en jours plutôt
        // que d'une addition de composant `.weekOfYear` — les deux
        // coïncident en pratique, mais ce ne serait plus « une seule
        // définition de semaine » si un jour ils divergeaient.
        let starts = (0..<weeks).compactMap { calendar.date(byAdding: .day, value: -7 * $0, to: currentWeekStart) }.reversed()

        let grouped = Dictionary(grouping: workouts) { workout in
            TrainingPlanner.monday(of: workout.startDate, calendar: calendar)
        }
        return starts.map { weekStart in
            let byActivity = Dictionary(grouping: grouped[weekStart] ?? []) { label(for: $0.activityType) }
                .mapValues { $0.reduce(0) { $0 + (durationMinutes($1) ?? 0) } }
            return WeekVolume(weekStart: weekStart, minutesByActivity: byActivity)
        }
    }
}
