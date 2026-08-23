import XCTest
import HealthKit
@testable import HealthCheckCompanion

private final class FakeReader: DeltaReading {
    var deltas: [String: TypeDelta] = [:]
    func delta(for typeIdentifier: String, since anchor: HKQueryAnchor?) async throws -> TypeDelta {
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

final class SyncEngineTests: XCTestCase {
    private var tempDir: URL!
    private var anchors: AnchorStore!
    private var reader: FakeReader!
    private var pusher: FakePusher!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        anchors = AnchorStore(directory: tempDir)
        reader = FakeReader()
        pusher = FakePusher()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func record(_ n: Int) -> ExchangeRecord {
        ExchangeRecord(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", device: nil,
                       unit: "count", value: Double(n),
                       startDate: Date(timeIntervalSince1970: Double(1_755_900_000 + n)),
                       endDate: Date(timeIntervalSince1970: Double(1_755_900_300 + n)), creationDate: nil)
    }

    private func engine(types: [String]) -> SyncEngine {
        SyncEngine(reader: reader, pusher: pusher, anchors: anchors, typeIdentifiers: types)
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

    func test_unauthorized_setsNeedsPairing_andStops() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        pusher.results = [.failure(MacClientError.unauthorized)]
        let report = await engine(types: [type, "HKQuantityTypeIdentifierHeartRate"]).syncAll()
        XCTAssertTrue(report.needsPairing)
        XCTAssertNil(anchors.anchor(for: type))
        XCTAssertEqual(pusher.pushedBatches.count, 1) // inutile d'insister sans jeton valide
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
}
