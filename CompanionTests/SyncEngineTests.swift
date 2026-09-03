import XCTest
import HealthKit
@testable import HealthCheckCompanion

private final class FakeReader: DeltaReading {
    var deltas: [String: TypeDelta] = [:]
    /// Sert un delta différent selon l'ancre reçue — sans ça, un fake qui
    /// ignore `since:` fait passer les tests de séparation des ancres même
    /// quand les deux consommateurs partagent la même.
    var provider: ((String, HKQueryAnchor?) -> TypeDelta)?
    private(set) var requestedAnchors: [String: [HKQueryAnchor?]] = [:]

    func delta(for typeIdentifier: String, since anchor: HKQueryAnchor?) async throws -> TypeDelta {
        requestedAnchors[typeIdentifier, default: []].append(anchor)
        if let provider { return provider(typeIdentifier, anchor) }
        guard let delta = deltas[typeIdentifier] else {
            return TypeDelta(typeIdentifier: typeIdentifier, records: [], sleep: [], workouts: [],
                             newAnchor: anchor ?? HKQueryAnchor(fromValue: 0))
        }
        return delta
    }
}

private final class FakePusher: BatchPushing {
    var pushedBatches: [ExchangeBatch] = []
    var results: [Result<Int, Error>] = []
    func push(batch: ExchangeBatch) async throws -> Int {
        pushedBatches.append(batch)
        guard !results.isEmpty else { return batch.records.count + batch.sleep.count + batch.workouts.count }
        switch results.removeFirst() {
        case .success(let n): return n
        case .failure(let e): throw e
        }
    }
}

private final class FakeImporter: LocalIngesting {
    var ingestedBatches: [ExchangeBatch] = []
    var shouldThrow = false
    func ingest(_ batch: ExchangeBatch) throws -> Int {
        if shouldThrow { throw NSError(domain: "FakeImporter", code: 1) }
        ingestedBatches.append(batch)
        return batch.records.count + batch.sleep.count + batch.workouts.count
    }
}

final class SyncEngineTests: XCTestCase {
    private var tempDir: URL!
    private var anchors: AnchorStore!
    private var localAnchors: AnchorStore!
    private var reader: FakeReader!
    private var pusher: FakePusher!
    private var importer: FakeImporter!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        anchors = AnchorStore(directory: tempDir.appendingPathComponent("mac", isDirectory: true))
        localAnchors = AnchorStore(directory: tempDir.appendingPathComponent("local", isDirectory: true))
        reader = FakeReader()
        pusher = FakePusher()
        importer = FakeImporter()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func record(_ n: Int) -> ExchangeRecord {
        ExchangeRecord(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", device: nil,
                       unit: "count", value: Double(n),
                       startDate: Date(timeIntervalSince1970: Double(1_755_900_000 + n)),
                       endDate: Date(timeIntervalSince1970: Double(1_755_900_300 + n)), creationDate: nil)
    }

    /// Sans type local-seul : ces suites-ci portent sur les ancres et le push
    /// d'un type donné, et la liste par défaut (`SyncEngine.localOnlyTypes`)
    /// leur ferait ingérer trois types de plus sans rapport avec leur objet.
    /// Les tests qui portent, eux, sur cette seconde liste utilisent
    /// `engine(types:localOnly:)`.
    private func engine(types: [String]) -> SyncEngine {
        SyncEngine(reader: reader, pusher: pusher, anchors: anchors, localAnchors: localAnchors,
                   localImporter: importer, typeIdentifiers: types, localOnlyTypeIdentifiers: [])
    }

    private func engine(types: [String], localOnly: [String]) -> SyncEngine {
        SyncEngine(reader: reader, pusher: pusher, anchors: anchors, localAnchors: localAnchors,
                   localImporter: importer, typeIdentifiers: types,
                   localOnlyTypeIdentifiers: localOnly)
    }

    func test_chunk_splitsAtLimit_preservingOrder() {
        let batch = ExchangeBatch(records: (0..<7).map(record), sleep: [], workouts: [])
        let chunks = SyncEngine.chunk(batch, limit: 3)
        XCTAssertEqual(chunks.map { $0.records.count }, [3, 3, 1])
        XCTAssertEqual(chunks[0].records[0].value, 0)
        XCTAssertEqual(chunks[2].records[0].value, 6)
    }

    func test_successfulSync_advancesAnchor_andReports() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1), record(2)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 7))
        let report = await engine(types: [type]).syncAll()
        XCTAssertEqual(report.pushedSamples, 2)
        XCTAssertEqual(report.insertedRows, 2)
        XCTAssertTrue(report.failedTypes.isEmpty)
        XCTAssertFalse(report.needsPairing)
        XCTAssertEqual(anchors.anchor(for: type), HKQueryAnchor(fromValue: 7)) // avancée après ack
    }

    func test_pushFailure_keepsAnchor_marksTypeFailed_othersContinue() async throws {
        let stepType = "HKQuantityTypeIdentifierStepCount"
        let hrType = "HKQuantityTypeIdentifierHeartRate"
        reader.deltas[stepType] = TypeDelta(typeIdentifier: stepType, records: [record(1)],
                                            sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        reader.deltas[hrType] = TypeDelta(typeIdentifier: hrType, records: [record(9)],
                                          sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 2))
        pusher.results = [.failure(MacClientError.unreachable), .success(1)]

        let report = await engine(types: [stepType, hrType]).syncAll()
        XCTAssertEqual(report.failedTypes, [stepType])
        XCTAssertNil(anchors.anchor(for: stepType))               // ancre intacte
        XCTAssertEqual(anchors.anchor(for: hrType), HKQueryAnchor(fromValue: 2)) // l'autre type avance
    }

    func test_multiBatchDelta_anchorAdvancesOnlyAfterLastAck() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        // 501 échantillons → 2 batchs au batchLimit de 500
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: (0..<501).map(record),
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 5))
        pusher.results = [.success(500), .failure(MacClientError.serverError(500))]

        let report = await engine(types: [type]).syncAll()
        XCTAssertEqual(pusher.pushedBatches.count, 2)
        XCTAssertEqual(report.failedTypes, [type])
        XCTAssertNil(anchors.anchor(for: type)) // échec au milieu du delta → tout sera relivré (idempotent côté Mac)
    }

    func test_unauthorized_stopsPushing_butKeepsIngestingLocally() async throws {
        let stepType = "HKQuantityTypeIdentifierStepCount"
        let hrType = "HKQuantityTypeIdentifierHeartRate"
        reader.deltas[stepType] = TypeDelta(typeIdentifier: stepType, records: [record(1)],
                                            sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        reader.deltas[hrType] = TypeDelta(typeIdentifier: hrType, records: [record(2)],
                                          sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 2))
        pusher.results = [.failure(MacClientError.unauthorized)]
        let report = await engine(types: [stepType, hrType]).syncAll()
        XCTAssertTrue(report.needsPairing)
        XCTAssertNil(anchors.anchor(for: stepType))
        XCTAssertNil(anchors.anchor(for: hrType))
        XCTAssertEqual(pusher.pushedBatches.count, 1) // inutile d'insister sans jeton valide
        XCTAssertEqual(importer.ingestedBatches.count, 2) // insertion locale indépendante de l'appairage
        XCTAssertEqual(report.failedTypes, [stepType, hrType])
    }

    func test_emptyDelta_pushesNothing() async {
        let report = await engine(types: ["HKQuantityTypeIdentifierStepCount"]).syncAll()
        XCTAssertEqual(report.pushedSamples, 0)
        XCTAssertTrue(pusher.pushedBatches.isEmpty)
    }

    // MARK: - C2 — distinguer Mac injoignable (réseau) de requête refusée (serveur)

    func test_serverErrorFailure_setsHadServerError() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        pusher.results = [.failure(MacClientError.serverError(500))]

        let report = await engine(types: [type]).syncAll()
        XCTAssertEqual(report.failedTypes, [type])
        XCTAssertTrue(report.hadServerError)
    }

    func test_unreachableFailure_doesNotSetHadServerError() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        pusher.results = [.failure(MacClientError.unreachable)]

        let report = await engine(types: [type]).syncAll()
        XCTAssertEqual(report.failedTypes, [type])
        XCTAssertFalse(report.hadServerError)
    }

    func test_successfulSync_alsoIngestsLocally() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1), record(2)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 7))
        _ = await engine(types: [type]).syncAll()
        XCTAssertEqual(importer.ingestedBatches.count, 1)
        XCTAssertEqual(importer.ingestedBatches[0].records.count, 2)
    }

    func test_pushFailure_stillIngestsLocally() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        pusher.results = [.failure(MacClientError.unreachable)]
        _ = await engine(types: [type]).syncAll()
        XCTAssertEqual(importer.ingestedBatches.count, 1) // insertion locale indépendante de l'échec du push
    }

    func test_localIngestFailure_doesNotBlockPush_orFailSync() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        importer.shouldThrow = true
        let report = await engine(types: [type]).syncAll()
        XCTAssertEqual(report.pushedSamples, 1)
        XCTAssertTrue(report.failedTypes.isEmpty)
        XCTAssertEqual(pusher.pushedBatches.count, 1)
    }

    func test_localIngestFailure_anchorStillAdvancesOnPushSuccess() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 3))
        importer.shouldThrow = true
        _ = await engine(types: [type]).syncAll()
        // Limite acceptée, spec §8 : l'ancre avance sur l'ack Mac seul, indépendamment
        // du succès de l'insertion locale.
        XCTAssertEqual(anchors.anchor(for: type), HKQueryAnchor(fromValue: 3))
    }

    // MARK: - Ancres locales séparées

    private func delta(_ type: String, records count: Int, newAnchor: Int) -> TypeDelta {
        TypeDelta(typeIdentifier: type, records: (0..<count).map(record), sleep: [], workouts: [],
                  newAnchor: HKQueryAnchor(fromValue: newAnchor))
    }

    /// Le cas de Vincent, 2026-09-01 : des mois de synchro vers le Mac avaient
    /// déjà consommé les ancres avant que la base locale n'existe, si bien que
    /// l'iPhone ne pouvait plus jamais recevoir son propre historique. Avec un
    /// jeu d'ancres distinct, la première ingestion locale repart d'une ancre
    /// nulle — donc de la fenêtre initiale de 180 jours.
    func test_syncAll_localIngestionReadsFromItsOwnAnchor_notTheMacOne() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        try anchors.save(HKQueryAnchor(fromValue: 42), for: type)
        reader.provider = { [weak self] type, anchor in
            guard let self else { fatalError() }
            return anchor == nil ? self.delta(type, records: 3, newAnchor: 99)
                                 : self.delta(type, records: 1, newAnchor: 100)
        }

        _ = await engine(types: [type]).syncAll()

        XCTAssertEqual(reader.requestedAnchors[type]?.count, 2, "une lecture pour le local, une pour le push")
        XCTAssertNil(reader.requestedAnchors[type]?.first ?? HKQueryAnchor(fromValue: 0),
                     "l'ingestion locale part de SON ancre, vierge — pas de celle du Mac")
        XCTAssertEqual(importer.ingestedBatches.first?.records.count, 3,
                       "le local reçoit le rattrapage complet, pas le delta déjà borné par l'ancre du Mac")
        XCTAssertEqual(pusher.pushedBatches.first?.records.count, 1,
                       "le Mac, lui, ne reçoit que ce qu'il n'a pas encore")
    }

    /// L'autonomie de l'iPhone ne doit rien devoir au Mac : un push en échec
    /// laisse l'ancre du Mac en place (relivraison) mais ne doit pas faire
    /// ré-ingérer localement la même fenêtre à chaque passe.
    func test_syncAll_localAnchorAdvancesEvenWhenTheMacPushFails() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.provider = { [weak self] type, anchor in
            guard let self else { fatalError() }
            return anchor == nil ? self.delta(type, records: 2, newAnchor: 7)
                                 : self.delta(type, records: 0, newAnchor: 7)
        }
        pusher.results = [.failure(MacClientError.unreachable)]

        _ = await engine(types: [type]).syncAll()
        XCTAssertNil(anchors.anchor(for: type), "push en échec : l'ancre du Mac ne bouge pas")
        XCTAssertNotNil(localAnchors.anchor(for: type), "l'insertion locale a réussi : son ancre avance")

        _ = await engine(types: [type]).syncAll()

        XCTAssertEqual(importer.ingestedBatches.count, 1,
                       "la seconde passe n'a rien de neuf à insérer localement")
        XCTAssertEqual(pusher.pushedBatches.count, 2, "le push, lui, est bien retenté")
    }

    /// (a) La passe d'ouverture : l'écran Conseils doit pouvoir travailler sur
    /// des données fraîches sans que le Mac soit joignable, ni même appairé —
    /// donc sans qu'aucune requête ne parte.
    func test_ingestLocalData_fillsTheLocalStoreWithoutTouchingTheMac() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = delta(type, records: 4, newAnchor: 11)

        let ingested = await engine(types: [type]).ingestLocalData()

        XCTAssertEqual(ingested, 4)
        XCTAssertEqual(importer.ingestedBatches.first?.records.count, 4)
        XCTAssertTrue(pusher.pushedBatches.isEmpty, "aucune requête ne doit partir vers le Mac")
        XCTAssertNotNil(localAnchors.anchor(for: type))
        XCTAssertNil(anchors.anchor(for: type), "l'ancre du Mac n'a rien à voir avec cette passe")
    }
    // MARK: - Types locaux seuls (SP5)

    /// Un enregistrement qui porte vraiment son type, contrairement au
    /// `record(_:)` de cette suite qui fabrique toujours des pas : sans ça, on
    /// ne pourrait pas distinguer un type corporel dans un batch poussé.
    private func typedRecord(_ type: String) -> ExchangeRecord {
        ExchangeRecord(type: type, sourceName: "Watch", device: nil, unit: "kg", value: 88.5,
                       startDate: Date(timeIntervalSince1970: 1_786_859_360),
                       endDate: Date(timeIntervalSince1970: 1_786_859_360),
                       creationDate: nil)
    }

    /// Le poids est lu pour l'écran Corps de l'iPhone et ne doit jamais partir
    /// vers le Mac, qui tient les mêmes mesures de Withings sous d'autres
    /// identifiants — les pousser y créerait de vrais doublons (spec §6).
    ///
    /// La garde observe ce qui atteint le pousseur, pas la composition des
    /// listes : comparer `localOnlyTypes` à `defaultTypes` serait vrai par
    /// construction et survivrait à la mutation qu'on veut attraper.
    func test_syncAll_ingestsLocalOnlyTypesLocallyAndPushesNoneOfThem() async throws {
        let pushed = "HKQuantityTypeIdentifierStepCount"
        let localOnly = SyncEngine.localOnlyTypes
        reader.provider = { [weak self] type, _ in
            guard let self else { fatalError() }
            return TypeDelta(typeIdentifier: type, records: [self.typedRecord(type)],
                             sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        }

        _ = await engine(types: [pushed], localOnly: localOnly).syncAll()

        let ingestedTypes = Set(importer.ingestedBatches.flatMap { $0.records.map(\.type) })
        for type in localOnly {
            XCTAssertTrue(ingestedTypes.contains(type),
                          "\(type) doit alimenter la base de l'iPhone")
        }

        let pushedTypes = Set(pusher.pushedBatches.flatMap { $0.records.map(\.type) })
        // Sans cette assertion, la suivante serait vraie d'un push entièrement
        // en panne — qui ne pousse rien, donc aucun type corporel non plus.
        XCTAssertTrue(pushedTypes.contains(pushed), "le push doit bien avoir eu lieu")
        for type in localOnly {
            XCTAssertFalse(pushedTypes.contains(type),
                           "\(type) ne doit jamais atteindre le Mac")
        }
    }

}
