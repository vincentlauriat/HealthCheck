import Foundation
import HealthKit

struct TypeDelta {
    let typeIdentifier: String
    let records: [ExchangeRecord]
    let sleep: [ExchangeSleep]
    let workouts: [ExchangeWorkout]
    let newAnchor: HKQueryAnchor
}

protocol DeltaReading {
    func delta(for typeIdentifier: String, since anchor: HKQueryAnchor?) async throws -> TypeDelta
}

protocol BatchPushing {
    func push(batch: ExchangeBatch) async throws -> Int
}

struct SyncReport: Equatable {
    var pushedSamples = 0
    var insertedRows = 0
    var failedTypes: [String] = []
    var needsPairing = false
    /// `true` dès qu'au moins un type a échoué avec un `.serverError` (Mac
    /// joignable mais requête refusée) plutôt qu'un `.unreachable` (Mac
    /// injoignable) — distingue les deux messages d'échec côté VM.
    var hadServerError = false
}

/// Orchestration de la synchro : par type, lire le delta depuis l'ancre,
/// pousser en batchs ≤ `batchLimit`, et n'avancer l'ancre qu'après l'ack du
/// DERNIER batch du delta. Un échec au milieu relivre tout le delta au
/// prochain passage — l'idempotence du Mac absorbe (spec §3/§9). Un 401
/// arrête tout : sans jeton valide, insister est inutile.
final class SyncEngine {
    static let defaultTypes: [String] = [
        HKQuantityTypeIdentifier.stepCount.rawValue,
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
        HKQuantityTypeIdentifier.heartRate.rawValue,
        HKQuantityTypeIdentifier.restingHeartRate.rawValue,
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
        HKQuantityTypeIdentifier.vo2Max.rawValue,
        "sleep",
        "workouts"
    ]

    private let reader: DeltaReading
    private let pusher: BatchPushing
    private let anchors: AnchorStore
    private let typeIdentifiers: [String]

    init(reader: DeltaReading, pusher: BatchPushing, anchors: AnchorStore,
         typeIdentifiers: [String] = SyncEngine.defaultTypes) {
        self.reader = reader
        self.pusher = pusher
        self.anchors = anchors
        self.typeIdentifiers = typeIdentifiers
    }

    static func chunk(_ batch: ExchangeBatch, limit: Int) -> [ExchangeBatch] {
        // Un delta est homogène (records OU sleep OU workouts) : découpage
        // simple par tableau, l'ordre est préservé.
        func slices<T>(_ items: [T]) -> [[T]] {
            stride(from: 0, to: items.count, by: limit).map { Array(items[$0..<min($0 + limit, items.count)]) }
        }
        if !batch.records.isEmpty {
            return slices(batch.records).map { ExchangeBatch(records: $0, sleep: [], workouts: []) }
        }
        if !batch.sleep.isEmpty {
            return slices(batch.sleep).map { ExchangeBatch(records: [], sleep: $0, workouts: []) }
        }
        if !batch.workouts.isEmpty {
            return slices(batch.workouts).map { ExchangeBatch(records: [], sleep: [], workouts: $0) }
        }
        return []
    }

    func syncAll() async -> SyncReport {
        var report = SyncReport()
        for type in typeIdentifiers {
            do {
                let delta = try await reader.delta(for: type, since: anchors.anchor(for: type))
                let sampleCount = delta.records.count + delta.sleep.count + delta.workouts.count
                guard sampleCount > 0 else { continue }

                let batches = Self.chunk(
                    ExchangeBatch(records: delta.records, sleep: delta.sleep, workouts: delta.workouts),
                    limit: CompanionProtocol.batchLimit
                )
                for batch in batches {
                    report.insertedRows += try await pusher.push(batch: batch)
                }
                // Tous les batchs ackés : l'ancre peut avancer.
                try anchors.save(delta.newAnchor, for: type)
                report.pushedSamples += sampleCount
            } catch MacClientError.unauthorized {
                report.needsPairing = true
                report.failedTypes.append(type)
                break // sans jeton valide, les types suivants échoueraient pareil
            } catch {
                report.failedTypes.append(type) // ancre intacte, relivraison au prochain passage
                if let macClientError = error as? MacClientError, case .serverError = macClientError {
                    report.hadServerError = true
                }
            }
        }
        return report
    }
}
