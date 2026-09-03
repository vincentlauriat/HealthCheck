import Foundation

/// Regroupe des enregistrements numériques (déjà résolus par priorité de
/// source) en un point par jour calendaire — moyenne pour les mesures
/// ponctuelles (FC, poids, HRV), total pour les cumuls (énergie, pas).
enum DailyAggregator {
    static func averages(_ records: [HealthRecord], calendar: Calendar) -> [TrendPoint] {
        Dictionary(grouping: records) { calendar.startOfDay(for: $0.startDate) }
            .map { day, values in
                TrendPoint(date: day, value: values.reduce(0) { $0 + $1.value } / Double(values.count),
                           sampleCount: values.count)
            }
            .sorted { $0.date < $1.date }
    }

    static func totals(_ records: [HealthRecord], calendar: Calendar) -> [TrendPoint] {
        Dictionary(grouping: records) { calendar.startOfDay(for: $0.startDate) }
            .map { day, values in
                // Pas de `sampleCount` ici : sur un **total**, le nombre
                // d'échantillons ne dit rien de la fiabilité de la valeur.
                // 506 échantillons d'énergie un jour et 94 le lendemain, ce
                // sont deux totaux également complets — l'afficher inviterait
                // à y lire une précision qui n'existe pas.
                TrendPoint(date: day, value: values.reduce(0) { $0 + $1.value })
            }
            .sorted { $0.date < $1.date }
    }
}
