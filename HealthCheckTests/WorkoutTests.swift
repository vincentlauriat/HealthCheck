import XCTest
@testable import HealthCheck

final class WorkoutTests: XCTestCase {
    private func makeWorkout(sourceName: String = "Watch") -> Workout {
        Workout(
            activityType: "HKWorkoutActivityTypeRunning",
            sourceName: sourceName,
            duration: 30,
            durationUnit: "min",
            totalDistance: 5,
            totalDistanceUnit: "km",
            totalEnergyBurned: 300,
            totalEnergyBurnedUnit: "kcal",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_001_800),
            routeFileName: "route_2026-08-18_1.gpx"
        )
    }

    func test_dedupKey_isStableForIdenticalWorkouts() {
        XCTAssertEqual(makeWorkout().dedupKey, makeWorkout().dedupKey)
    }

    func test_dedupKey_differsWhenSourceDiffers() {
        XCTAssertNotEqual(makeWorkout(sourceName: "Watch").dedupKey, makeWorkout(sourceName: "iPhone").dedupKey)
    }
}
