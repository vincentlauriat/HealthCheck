import Foundation

/// Effort d'une journée : minutes passées dans chaque zone cardiaque et
/// score 0-100.
struct DayStrain: Equatable {
    let day: Date
    /// Minutes en Z1…Z5 (50-60 %, 60-70 %, 70-80 %, 80-90 %, 90 %+ de FC max).
    let zoneMinutes: [Double]
    let score: Double
}

/// Calcule l'effort quotidien à partir des échantillons de FC continue.
/// Chaque échantillon « vaut » l'intervalle jusqu'au suivant (plafonné à
/// 5 min pour ne pas sur-compter les trous de mesure). Les minutes par zone
/// sont pondérées (zones hautes = effort disproportionné, comme Whoop/Bevel)
/// puis rapportées à une journée très intense (≈ 60 min de Z4 → score 70).
enum StrainEngine {
    /// Bornes basses des zones, en fraction de la FC max.
    static let zoneLowerBounds: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    static let zoneWeights: [Double] = [1, 2, 4, 7, 10]
    static let maxSampleGapMinutes = 5.0
    /// Charge pondérée correspondant à un score de 100.
    static let fullScoreLoad = 600.0

    static func dayStrains(samples: [HealthRecord], maxHeartRate: Double, calendar: Calendar) -> [DayStrain] {
        guard maxHeartRate > 0 else { return [] }
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        // Durée « couverte » par chaque échantillon = jusqu'au suivant, plafonnée.
        var perDayZoneMinutes: [Date: [Double]] = [:]
        for (index, sample) in sorted.enumerated() {
            let minutes: Double
            if index + 1 < sorted.count {
                minutes = min(sorted[index + 1].startDate.timeIntervalSince(sample.startDate) / 60, maxSampleGapMinutes)
            } else {
                minutes = 1
            }
            let fraction = sample.value / maxHeartRate
            guard let zone = zoneIndex(for: fraction) else { continue }
            let day = calendar.startOfDay(for: sample.startDate)
            perDayZoneMinutes[day, default: [0, 0, 0, 0, 0]][zone] += minutes
        }

        return perDayZoneMinutes
            .map { day, zones -> DayStrain in
                let load = zip(zones, zoneWeights).reduce(0) { $0 + $1.0 * $1.1 }
                return DayStrain(day: day, zoneMinutes: zones, score: min(load / fullScoreLoad * 100, 100))
            }
            .sorted { $0.day < $1.day }
    }

    static func zoneIndex(for fraction: Double) -> Int? {
        guard fraction >= zoneLowerBounds[0] else { return nil }
        for index in stride(from: zoneLowerBounds.count - 1, through: 0, by: -1) where fraction >= zoneLowerBounds[index] {
            return index
        }
        return nil
    }

    static func label(for score: Double) -> String {
        switch score {
        case 70...: return "Effort intense"
        case 40..<70: return "Effort soutenu"
        case 15..<40: return "Effort modéré"
        default: return "Journée légère"
        }
    }
}
