import Foundation

struct SourcePriorityResolver {
    let priority: [String]

    func resolve<T: TimedHealthValue>(_ records: [T]) -> [T] {
        var kept: [T] = []
        // Balayage : seuls les enregistrements encore « ouverts » (endDate
        // postérieure au début du candidat) peuvent chevaucher. Sans cette
        // fenêtre, la recherche est quadratique — plusieurs secondes de gel
        // sur les ~30 000 échantillons d'énergie d'un semestre.
        var activeIndices: [Int] = []

        for record in records.sorted(by: { $0.startDate < $1.startDate }) {
            activeIndices.removeAll { kept[$0].endDate <= record.startDate }
            let overlapIndex = activeIndices.first { index in
                let existing = kept[index]
                return existing.type == record.type &&
                    existing.startDate < record.endDate &&
                    record.startDate < existing.endDate
            }

            guard let overlapIndex else {
                kept.append(record)
                activeIndices.append(kept.count - 1)
                continue
            }

            let existing = kept[overlapIndex]
            let existingRank = priority.firstIndex(of: existing.sourceName)
            let candidateRank = priority.firstIndex(of: record.sourceName)

            switch (existingRank, candidateRank) {
            case let (.some(e), .some(c)) where c < e:
                kept[overlapIndex] = record
            case (.none, .some):
                kept[overlapIndex] = record
            default:
                break // existing wins, or neither is ranked — first one seen stays
            }
        }

        return kept
    }
}
