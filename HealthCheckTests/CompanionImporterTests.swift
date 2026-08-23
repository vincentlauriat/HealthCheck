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
}
