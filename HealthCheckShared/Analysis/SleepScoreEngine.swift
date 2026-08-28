import Foundation

/// Une nuit résumée : durées par phase, réveils, et score 0-100.
struct NightSummary: Equatable {
    let night: Date
    let asleepHours: Double
    let deepHours: Double
    let remHours: Double
    let coreHours: Double
    let awakeCount: Int
    let score: Double
}

/// Score de sommeil par nuit, façon Withings :
/// durée 50 pts (cible 8 h) · profond 20 pts (cible ≥ 15 % du sommeil) ·
/// REM 20 pts (cible ≥ 20 %) · continuité 10 pts (réveils).
/// Les nuits sans données de phase (watchOS < 9 : tout en `Unspecified`)
/// sont notées sur la durée seule, rebasée sur 100 — sinon elles
/// plafonneraient injustement à 60.
enum SleepScoreEngine {
    static let targetHours = 8.0
    static let deepTargetShare = 0.15
    static let remTargetShare = 0.20

    static func summarize(_ records: [SleepRecord], calendar: Calendar) -> [NightSummary] {
        let relevant = records.filter { $0.value != "HKCategoryValueSleepAnalysisInBed" }
        let grouped = Dictionary(grouping: relevant) { record in
            calendar.startOfDay(for: record.startDate.addingTimeInterval(-12 * 3600))
        }

        return grouped
            .map { night, segments -> NightSummary in
                var deep = 0.0, rem = 0.0, core = 0.0
                var awakeCount = 0
                for segment in segments {
                    let hours = segment.endDate.timeIntervalSince(segment.startDate) / 3600
                    switch segment.value {
                    case "HKCategoryValueSleepAnalysisAsleepDeep": deep += hours
                    case "HKCategoryValueSleepAnalysisAsleepREM": rem += hours
                    case "HKCategoryValueSleepAnalysisAwake": awakeCount += 1
                    default:
                        if segment.value.hasPrefix("HKCategoryValueSleepAnalysisAsleep") { core += hours }
                    }
                }
                let asleep = deep + rem + core
                return NightSummary(
                    night: night,
                    asleepHours: asleep,
                    deepHours: deep,
                    remHours: rem,
                    coreHours: core,
                    awakeCount: awakeCount,
                    score: score(asleep: asleep, deep: deep, rem: rem, awakeCount: awakeCount)
                )
            }
            .filter { $0.asleepHours > 0 }
            .sorted { $0.night < $1.night }
    }

    static func score(asleep: Double, deep: Double, rem: Double, awakeCount: Int) -> Double {
        guard asleep > 0 else { return 0 }
        let durationRatio = min(asleep / targetHours, 1)

        // Pas de données de phase → score sur la durée seule.
        guard deep + rem > 0 else { return durationRatio * 100 }

        let durationPoints = durationRatio * 50
        let deepPoints = min((deep / asleep) / deepTargetShare, 1) * 20
        let remPoints = min((rem / asleep) / remTargetShare, 1) * 20
        let continuityPoints = max(0, 1 - Double(awakeCount) / 8) * 10
        return durationPoints + deepPoints + remPoints + continuityPoints
    }
}
