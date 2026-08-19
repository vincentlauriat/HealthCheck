import Foundation

struct SourcePriorityResolver {
    let priority: [String]

    func resolve<T: TimedHealthValue>(_ records: [T]) -> [T] {
        var kept: [T] = []

        for record in records.sorted(by: { $0.startDate < $1.startDate }) {
            let overlapIndex = kept.firstIndex { existing in
                existing.type == record.type &&
                existing.startDate < record.endDate &&
                record.startDate < existing.endDate
            }

            guard let overlapIndex else {
                kept.append(record)
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
