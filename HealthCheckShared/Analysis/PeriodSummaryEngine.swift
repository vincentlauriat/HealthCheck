import Foundation

struct PeriodSummary {
    let steps: Double
    let distanceKm: Double
    let activeEnergyKcal: Double
    let exerciseMinutes: Double
    let restingHeartRate: Double?
}

/// Agrégats d'une fenêtre de temps : les quatre totaux d'activité et la
/// dernière FC repos connue. Extrait de `DashboardViewModel` pour que
/// l'Accueil de l'iPhone produise exactement les mêmes chiffres que celui du
/// Mac, plutôt que de redécrire les mêmes sommes.
enum PeriodSummaryEngine {
    static func summary(store: HealthStore, resolver: SourcePriorityResolver,
                        from: Date, to: Date) throws -> PeriodSummary {
        PeriodSummary(
            steps: try sum("HKQuantityTypeIdentifierStepCount", store, resolver, from, to),
            distanceKm: try sum("HKQuantityTypeIdentifierDistanceWalkingRunning", store, resolver, from, to),
            activeEnergyKcal: try sum("HKQuantityTypeIdentifierActiveEnergyBurned", store, resolver, from, to),
            exerciseMinutes: try sum("HKQuantityTypeIdentifierAppleExerciseTime", store, resolver, from, to),
            restingHeartRate: try resolver
                .resolve(store.records(type: "HKQuantityTypeIdentifierRestingHeartRate", from: from, to: to))
                .sorted(by: { $0.startDate > $1.startDate })
                .first?.value
        )
    }

    /// La journée en cours, de son début à son lendemain.
    static func today(store: HealthStore, resolver: SourcePriorityResolver,
                      calendar: Calendar, now: Date) throws -> PeriodSummary {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return try summary(store: store, resolver: resolver, from: startOfDay, to: endOfDay)
    }

    /// La semaine en cours, et la précédente **à portion écoulée égale** :
    /// mercredi 15 h se compare au mercredi 15 h de la semaine passée, pas à
    /// sa semaine complète.
    static func weekToDate(store: HealthStore, resolver: SourcePriorityResolver,
                           calendar: Calendar, now: Date) throws -> (thisWeek: PeriodSummary, lastWeek: PeriodSummary?) {
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)!
        let thisWeek = try summary(store: store, resolver: resolver, from: interval.start, to: interval.end)

        guard let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start) else {
            return (thisWeek, nil)
        }
        let elapsed = now.timeIntervalSince(interval.start)
        let lastWeek = try summary(store: store, resolver: resolver,
                                   from: lastWeekStart, to: lastWeekStart.addingTimeInterval(elapsed))
        return (thisWeek, lastWeek)
    }

    private static func sum(_ type: String, _ store: HealthStore, _ resolver: SourcePriorityResolver,
                            _ from: Date, _ to: Date) throws -> Double {
        resolver.resolve(try store.records(type: type, from: from, to: to)).reduce(0) { $0 + $1.value }
    }
}
