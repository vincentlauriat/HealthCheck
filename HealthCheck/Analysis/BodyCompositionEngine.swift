import Foundation

/// Photographie journalière de la composition corporelle. Masses en kg,
/// `fatShare` en fraction (0,25 = 25 %). `fatMass` est dérivée : la balance
/// ne synchronise vers Apple Santé que le poids, le % de graisse, la masse
/// maigre et l'IMC.
struct BodySnapshot: Equatable {
    let day: Date
    let weight: Double
    let fatShare: Double?
    let leanMass: Double?
    let bmi: Double?

    var fatMass: Double? { fatShare.map { weight * $0 } }
}

enum BodyCompositionEngine {
    /// Joint les séries journalières sur les jours où un poids existe —
    /// sans poids, ni la masse grasse en kg ni l'IMC ne sont interprétables.
    /// Les entrées sont des points journaliers (un par jour calendaire),
    /// typiquement issus de `DailyAggregator.averages`.
    static func dailySnapshots(
        weights: [TrendPoint],
        fatShares: [TrendPoint],
        leanMasses: [TrendPoint],
        bmis: [TrendPoint]
    ) -> [BodySnapshot] {
        let fatByDay = Dictionary(uniqueKeysWithValues: fatShares.map { ($0.date, $0.value) })
        let leanByDay = Dictionary(uniqueKeysWithValues: leanMasses.map { ($0.date, $0.value) })
        let bmiByDay = Dictionary(uniqueKeysWithValues: bmis.map { ($0.date, $0.value) })
        return weights
            .map {
                BodySnapshot(
                    day: $0.date,
                    weight: $0.value,
                    fatShare: fatByDay[$0.date],
                    leanMass: leanByDay[$0.date],
                    bmi: bmiByDay[$0.date]
                )
            }
            .sorted { $0.day < $1.day }
    }

    /// Référence d'un delta « il y a N jours » : la photographie la plus
    /// récente à cette date ou avant (on ne se pèse pas tous les jours).
    static func reference(in snapshots: [BodySnapshot], onOrBefore date: Date) -> BodySnapshot? {
        snapshots.last { $0.day <= date }
    }
}
