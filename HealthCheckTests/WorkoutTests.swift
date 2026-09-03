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

    /// Même séance, deux chemins d'ingestion : l'export XML arrondit la durée
    /// et n'horodate qu'à la seconde. Cf. `HealthRecordTests`.
    func test_dedupKey_isTheSameWhicheverImportPathDescribedTheWorkout() {
        let second = Date(timeIntervalSince1970: 1_755_323_360)
        let fromExport = Workout(
            activityType: "HKWorkoutActivityTypeRunning", sourceName: "Apple Watch de Vincent",
            duration: 30.1235, durationUnit: "min",
            totalDistance: 5, totalDistanceUnit: "km",
            totalEnergyBurned: 300, totalEnergyBurnedUnit: "kcal",
            startDate: second, endDate: second.addingTimeInterval(1800),
            routeFileName: nil
        )
        let fromSync = Workout(
            activityType: "HKWorkoutActivityTypeRunning", sourceName: "Apple Watch de Vincent",
            duration: 30.123456789, durationUnit: "min",
            totalDistance: 5, totalDistanceUnit: "km",
            totalEnergyBurned: 300, totalEnergyBurnedUnit: "kcal",
            startDate: second.addingTimeInterval(0.622),
            endDate: second.addingTimeInterval(1800.111),
            routeFileName: "route_2026-08-18_1.gpx"
        )
        XCTAssertEqual(fromExport.dedupKey, fromSync.dedupKey,
                       "une même séance ne doit pas produire deux lignes selon son chemin d'import")
    }
}
