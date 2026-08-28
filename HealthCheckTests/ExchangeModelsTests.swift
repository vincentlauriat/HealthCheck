import XCTest
@testable import HealthCheck

final class ExchangeModelsTests: XCTestCase {
    func test_batch_roundTripsThroughJSON() throws {
        let start = Date(timeIntervalSince1970: 1_755_900_000.123)
        let batch = ExchangeBatch(
            records: [ExchangeRecord(
                type: "HKQuantityTypeIdentifierRestingHeartRate",
                sourceName: "Watch", device: nil, unit: "count/min",
                value: 61, startDate: start, endDate: start, creationDate: start)],
            sleep: [ExchangeSleep(
                type: "HKCategoryTypeIdentifierSleepAnalysis",
                sourceName: "Watch", device: nil,
                value: "HKCategoryValueSleepAnalysisAsleepDeep",
                startDate: start, endDate: start.addingTimeInterval(1800), creationDate: nil)],
            workouts: [ExchangeWorkout(
                activityType: "HKWorkoutActivityTypeRunning",
                sourceName: "Watch", duration: 30, durationUnit: "min",
                totalDistance: 5, totalDistanceUnit: "km",
                totalEnergyBurned: 300, totalEnergyBurnedUnit: "kcal",
                startDate: start, endDate: start.addingTimeInterval(1800),
                routePoints: [ExchangeRoutePoint(latitude: 48.85, longitude: 2.35, timestamp: start)])])

        let data = try ExchangeCoding.encoder.encode(batch)
        let decoded = try ExchangeCoding.decoder.decode(ExchangeBatch.self, from: data)
        XCTAssertEqual(decoded, batch)
    }

    func test_dates_encodeWithFractionalSeconds() throws {
        let record = ExchangeRecord(
            type: "t", sourceName: "s", device: nil, unit: nil, value: 1,
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 0),
            creationDate: nil)
        let json = String(data: try ExchangeCoding.encoder.encode(record), encoding: .utf8)!
        XCTAssertTrue(json.contains("1970-01-01T00:00:00.000Z"), json)
    }

    func test_trainingPlan_roundTripsThroughJSON() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_777_000_000.456)
        let response = TrainingPlanResponse(
            generatedAt: generatedAt,
            goal: TrainingGoalSummary(name: "Trail", raceDate: generatedAt, distanceKm: 21.1, elevationGainM: 600),
            weeks: [TrainingWeekSummary(
                monday: generatedAt,
                role: "Construction",
                targetKm: 32.5,
                sessions: [TrainingSessionSummary(
                    kind: "Sortie longue",
                    targetText: "14,0 km",
                    detailText: "126-145 bpm · endurance",
                    note: "Terrain facile",
                    rationale: "Construire l'endurance",
                    isOptional: false
                )]
            )],
            message: nil
        )

        let data = try ExchangeCoding.encoder.encode(response)
        let decoded = try ExchangeCoding.decoder.decode(TrainingPlanResponse.self, from: data)

        XCTAssertEqual(decoded, response)
    }

    func test_protocolConstants() {
        XCTAssertEqual(CompanionProtocol.serviceType, "_healthcheck._tcp")
        XCTAssertEqual(CompanionProtocol.batchLimit, 500)
        XCTAssertEqual(CompanionProtocol.trainingPlanPath, "/training-plan")
    }
}
