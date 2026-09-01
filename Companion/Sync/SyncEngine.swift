import Foundation
import HealthKit
import os.log

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

protocol LocalIngesting {
    func ingest(_ batch: ExchangeBatch) throws -> Int
}

extension CompanionImporter: LocalIngesting {}

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
    private let localAnchors: AnchorStore
    private let localImporter: LocalIngesting
    private let typeIdentifiers: [String]

    init(reader: DeltaReading, pusher: BatchPushing, anchors: AnchorStore,
         localAnchors: AnchorStore, localImporter: LocalIngesting,
         typeIdentifiers: [String] = SyncEngine.defaultTypes) {
        self.reader = reader
        self.pusher = pusher
        self.anchors = anchors
        self.localAnchors = localAnchors
        self.localImporter = localImporter
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
        var pushDisabled = false
        for type in typeIdentifiers {
            await ingestLocally(type)

            guard !pushDisabled else {
                report.failedTypes.append(type) // ancre Mac intacte, relivraison au prochain passage
                continue
            }
            do {
                let delta = try await reader.delta(for: type, since: anchors.anchor(for: type))
                let sampleCount = delta.records.count + delta.sleep.count + delta.workouts.count
                guard sampleCount > 0 else { continue }

                let fullBatch = ExchangeBatch(records: delta.records, sleep: delta.sleep, workouts: delta.workouts)
                let batches = Self.chunk(fullBatch, limit: CompanionProtocol.batchLimit)
                for batch in batches {
                    report.insertedRows += try await pusher.push(batch: batch)
                }
                // Tous les batchs ackés : l'ancre peut avancer.
                try anchors.save(delta.newAnchor, for: type)
                report.pushedSamples += sampleCount
            } catch MacClientError.unauthorized {
                report.needsPairing = true
                report.failedTypes.append(type)
                // Insertion locale continue pour les types suivants (spec §6 : l'autonomie
                // ne doit jamais dépendre du Mac) ; seul le push s'arrête — sans jeton
                // valide, insister échouerait pareil pour tous les types restants.
                pushDisabled = true
            } catch {
                report.failedTypes.append(type) // ancre Mac intacte, relivraison au prochain passage
                if let macClientError = error as? MacClientError, case .serverError = macClientError {
                    report.hadServerError = true
                }
            }
        }
        return report
    }

    /// Alimente la base de l'iPhone, sur son propre jeu d'ancres : ni le
    /// résultat du push, ni même l'appairage n'entrent ici. L'ancre locale
    /// n'avance qu'après une insertion réussie — un store indisponible ou un
    /// disque plein fait relire la même fenêtre à la passe suivante.
    private func ingestLocally(_ type: String) async {
        do {
            let delta = try await reader.delta(for: type, since: localAnchors.anchor(for: type))
            let sampleCount = delta.records.count + delta.sleep.count + delta.workouts.count
            guard sampleCount > 0 else { return }
            _ = try localImporter.ingest(ExchangeBatch(records: delta.records, sleep: delta.sleep,
                                                       workouts: delta.workouts))
            try localAnchors.save(delta.newAnchor, for: type)
        } catch {
            os_log(.error, "Insertion locale échouée pour %{public}@: %{public}@",
                   type, String(describing: error))
        }
    }
}
