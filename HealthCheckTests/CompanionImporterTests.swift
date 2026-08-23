import XCTest
@testable import HealthCheck

final class CompanionImporterTests: XCTestCase {
    private var routesDir: URL!
    private var importer: CompanionImporter!
    private var store: HealthStore!

    override func setUpWithError() throws {
        routesDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("routes-\(UUID().uuidString)", isDirectory: true)
        store = try HealthStore(path: ":memory:")
        importer = CompanionImporter(store: store, routeStore: RouteStore(directory: routesDir))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: routesDir)
    }

    private var sampleBatch: ExchangeBatch {
        let start = Date(timeIntervalSince1970: 1_755_900_000)
        return ExchangeBatch(
            records: [ExchangeRecord(type: "HKQuantityTypeIdentifierStepCount",
                sourceName: "Watch", device: nil, unit: "count", value: 500,
                startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)],
            sleep: [ExchangeSleep(type: "HKCategoryTypeIdentifierSleepAnalysis",
                sourceName: "Watch", device: nil, value: "HKCategoryValueSleepAnalysisAsleepDeep",
                startDate: start, endDate: start.addingTimeInterval(1800), creationDate: nil)],
            workouts: [ExchangeWorkout(activityType: "HKWorkoutActivityTypeRunning",
                sourceName: "Watch", duration: 30, durationUnit: "min",
                totalDistance: 5, totalDistanceUnit: "km",
                totalEnergyBurned: 300, totalEnergyBurnedUnit: "kcal",
                startDate: start, endDate: start.addingTimeInterval(1800),
                routePoints: [ExchangeRoutePoint(latitude: 48.85, longitude: 2.35, timestamp: start),
                              ExchangeRoutePoint(latitude: 48.86, longitude: 2.36, timestamp: start.addingTimeInterval(60))])])
    }

    func test_ingest_insertsAllThreeKinds_andIsIdempotent() throws {
        XCTAssertEqual(try importer.ingest(sampleBatch), 3)
        XCTAssertEqual(try importer.ingest(sampleBatch), 0) // re-livraison at-least-once
        let from = Date(timeIntervalSince1970: 1_755_800_000)
        let to = Date(timeIntervalSince1970: 1_756_000_000)
        XCTAssertEqual(try store.records(type: "HKQuantityTypeIdentifierStepCount", from: from, to: to).count, 1)
        XCTAssertEqual(try store.sleepRecords(from: from, to: to).count, 1)
        XCTAssertEqual(try store.workouts(from: from, to: to).count, 1)
    }

    func test_ingest_writesParsableGPXAndLinksWorkout() throws {
        _ = try importer.ingest(sampleBatch)
        let from = Date(timeIntervalSince1970: 1_755_800_000)
        let to = Date(timeIntervalSince1970: 1_756_000_000)
        let workout = try XCTUnwrap(try store.workouts(from: from, to: to).first)
        let fileName = try XCTUnwrap(workout.routeFileName)
        XCTAssertTrue(fileName.hasPrefix("companion_"))
        let url = try XCTUnwrap(RouteStore(directory: routesDir).url(forRouteFileName: fileName))
        let points = GPXParser.points(from: try Data(contentsOf: url))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].latitude, 48.85, accuracy: 0.0001)
    }

    func test_ingest_workoutWithoutPoints_hasNoRouteFile() throws {
        let start = Date(timeIntervalSince1970: 1_755_900_000)
        let batch = ExchangeBatch(records: [], sleep: [], workouts: [
            ExchangeWorkout(activityType: "HKWorkoutActivityTypeWalking",
                sourceName: "Watch", duration: 20, durationUnit: "min",
                totalDistance: nil, totalDistanceUnit: nil,
                totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                startDate: start, endDate: start.addingTimeInterval(1200), routePoints: nil)])
        XCTAssertEqual(try importer.ingest(batch), 1)
        let workout = try store.workouts(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1)).first
        XCTAssertNil(workout?.routeFileName)
    }

    func test_ingest_selfHealing_routeWriteFailThenSucceed() throws {
        // Phase 1: Ingest with a blocked directory (file instead of directory)
        let blockedDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blocked-route-\(UUID().uuidString)")
        try Data().write(to: blockedDir) // Create a FILE, not a directory
        let blockedImporter = CompanionImporter(store: store, routeStore: RouteStore(directory: blockedDir))

        // First delivery: routeFileName is stored despite write failure (self-healing setup)
        XCTAssertEqual(try blockedImporter.ingest(sampleBatch), 3)
        let from = Date(timeIntervalSince1970: 1_755_800_000)
        let to = Date(timeIntervalSince1970: 1_756_000_000)
        let workoutPhase1 = try XCTUnwrap(try store.workouts(from: from, to: to).first)
        let fileName = try XCTUnwrap(workoutPhase1.routeFileName)

        // File is absent: url(forRouteFileName:) returns nil with blocked directory
        XCTAssertNil(RouteStore(directory: blockedDir).url(forRouteFileName: fileName))

        try FileManager.default.removeItem(at: blockedDir)

        // Phase 2: Re-ingest with a good directory
        let goodDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("good-route-\(UUID().uuidString)", isDirectory: true)
        let healingImporter = CompanionImporter(store: store, routeStore: RouteStore(directory: goodDir))

        // Idempotent: no new rows (same dedupKey, routeFileName already set)
        XCTAssertEqual(try healingImporter.ingest(sampleBatch), 0)

        // Now file exists and resolves via the deterministic name
        let goodRouteStore = RouteStore(directory: goodDir)
        let url = try XCTUnwrap(goodRouteStore.url(forRouteFileName: fileName))
        let points = GPXParser.points(from: try Data(contentsOf: url))
        XCTAssertEqual(points.count, 2)

        try FileManager.default.removeItem(at: goodDir)
    }
}
