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

    /// Décomposition du poids en arbre pour un diagramme de Sankey :
    /// Poids → Masse maigre + Masse grasse, puis Maigre → Muscle + Os +
    /// Autres tissus. L'eau corporelle n'y figure pas : elle est
    /// transversale (contenue dans le muscle et les organes) et ne
    /// s'additionne pas aux autres compartiments.
    static func weightSankey(weight: Double, fatMass: Double?, muscle: Double?, bone: Double?) -> WeightSankey? {
        guard weight > 0, let fatMass, fatMass >= 0, fatMass < weight else { return nil }
        let lean = weight - fatMass

        var nodes: [WeightSankey.Node] = [
            .init(id: "poids", label: "Poids total", kg: weight, column: 0),
            .init(id: "maigre", label: "Masse maigre", kg: lean, column: 1),
            .init(id: "graisse", label: "Masse grasse", kg: fatMass, column: 1)
        ]
        var links: [WeightSankey.Link] = [
            .init(from: "poids", to: "maigre", kg: lean),
            .init(from: "poids", to: "graisse", kg: fatMass)
        ]

        // Niveau 2 : uniquement si la balance fournit au moins un compartiment
        // de la masse maigre. « Autres tissus » = le reste (organes, peau…),
        // omis s'il est négligeable ou incohérent (muscle + os > maigre).
        var leanChildren: [(id: String, label: String, kg: Double)] = []
        if let muscle, muscle > 0 { leanChildren.append(("muscle", "Muscle", muscle)) }
        if let bone, bone > 0 { leanChildren.append(("os", "Os", bone)) }
        if !leanChildren.isEmpty {
            let rest = lean - leanChildren.reduce(0) { $0 + $1.kg }
            if rest > 0.05 { leanChildren.append(("autres", "Autres tissus", rest)) }
            for child in leanChildren {
                nodes.append(.init(id: child.id, label: child.label, kg: child.kg, column: 2))
                links.append(.init(from: "maigre", to: child.id, kg: child.kg))
            }
        }
        return WeightSankey(nodes: nodes, links: links, totalKg: weight)
    }
}

/// Arbre de répartition du poids, indépendant de SwiftUI pour rester testable.
struct WeightSankey: Equatable {
    struct Node: Equatable {
        let id: String
        let label: String
        let kg: Double
        let column: Int
    }

    struct Link: Equatable {
        let from: String
        let to: String
        let kg: Double
    }

    let nodes: [Node]
    let links: [Link]
    let totalKg: Double
}
