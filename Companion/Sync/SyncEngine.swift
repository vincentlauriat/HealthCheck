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

    /// Types lus pour l'iPhone seul et **jamais poussés**. Le Mac possède déjà
    /// ces mesures via l'API Withings, sous d'autres identifiants de source ;
    /// une pesée ayant une durée nulle, `SourcePriorityResolver` ne la
    /// dédoublonne pas (suivi M2), et les pousser créerait de vrais doublons
    /// dans la base du Mac.
    static let localOnlyTypes: [String] = [
        HKQuantityTypeIdentifier.bodyMass.rawValue,
        HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
        HKQuantityTypeIdentifier.leanBodyMass.rawValue
    ]

    private let reader: DeltaReading
    private let pusher: BatchPushing
    private let anchors: AnchorStore
    private let localAnchors: AnchorStore
    private let localImporter: LocalIngesting
    private let typeIdentifiers: [String]
    private let localOnlyTypeIdentifiers: [String]

    init(reader: DeltaReading, pusher: BatchPushing, anchors: AnchorStore,
         localAnchors: AnchorStore, localImporter: LocalIngesting,
         typeIdentifiers: [String] = SyncEngine.defaultTypes,
         localOnlyTypeIdentifiers: [String] = SyncEngine.localOnlyTypes) {
        self.reader = reader
        self.pusher = pusher
        self.anchors = anchors
        self.localAnchors = localAnchors
        self.localImporter = localImporter
        self.typeIdentifiers = typeIdentifiers
        self.localOnlyTypeIdentifiers = localOnlyTypeIdentifiers
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
        // Ingérés ici aussi : `syncAll()` est l'autre chemin qui alimente la
        // base locale, et sans cette boucle « Envoyer au Mac » sauterait
        // silencieusement le poids. Le push, lui, ne voit que `typeIdentifiers`.
        for type in localOnlyTypeIdentifiers {
            await ingestLocally(type)
        }
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

    /// Actualise la base de l'iPhone sans jamais parler au Mac : c'est ce que
    /// l'app fait à l'ouverture, pour que l'écran Conseils travaille sur des
    /// données fraîches sans attendre une découverte Bonjour ni un timeout
    /// réseau. Le push reste au bouton « Envoyer au Mac » et au réveil
    /// d'arrière-plan.
    @discardableResult
    func ingestLocalData() async -> Int {
        var ingested = 0
        for type in typeIdentifiers + localOnlyTypeIdentifiers {
            ingested += await ingestLocally(type)
        }
        return ingested
    }

    /// Alimente la base de l'iPhone, sur son propre jeu d'ancres : ni le
    /// résultat du push, ni même l'appairage n'entrent ici. L'ancre locale
    /// n'avance qu'après une insertion réussie — un store indisponible ou un
    /// disque plein fait relire la même fenêtre à la passe suivante.
    @discardableResult
    private func ingestLocally(_ type: String) async -> Int {
        do {
            let delta = try await reader.delta(for: type, since: localAnchors.anchor(for: type))
            let sampleCount = delta.records.count + delta.sleep.count + delta.workouts.count
            guard sampleCount > 0 else { return 0 }
            _ = try localImporter.ingest(ExchangeBatch(records: delta.records, sleep: delta.sleep,
                                                       workouts: delta.workouts))
            try localAnchors.save(delta.newAnchor, for: type)
            return sampleCount
        } catch {
            os_log(.error, "Insertion locale échouée pour %{public}@: %{public}@",
                   type, String(describing: error))
            return 0
        }
    }
}
