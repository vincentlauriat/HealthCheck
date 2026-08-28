import Foundation

/// Transforme des segments de sommeil bruts (déjà résolus par priorité de
/// source) en heures dormies par nuit. Une « nuit » est le jour calendaire de
/// `startDate - 12h`, pour qu'une session 23h→7h reste une seule nuit. Seuls
/// les segments `Asleep*` comptent (Core/Deep/REM/Unspecified + l'ancienne
/// valeur `Asleep`) — `InBed` et `Awake` sont exclus.
enum SleepAggregator {
    static func nightlyHours(_ records: [SleepRecord], calendar: Calendar) -> [TrendPoint] {
        let asleep = records.filter { $0.value.hasPrefix("HKCategoryValueSleepAnalysisAsleep") }
        let grouped = Dictionary(grouping: asleep) { record in
            calendar.startOfDay(for: record.startDate.addingTimeInterval(-12 * 3600))
        }
        return grouped
            .map { night, segments -> TrendPoint in
                let totalSeconds = segments.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                return TrendPoint(date: night, value: totalSeconds / 3600)
            }
            .sorted { $0.date < $1.date }
    }
}
