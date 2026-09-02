import XCTest
@testable import HealthCheckCompanion

/// Sur l'iPhone la table `race_goal` est vide — les objectifs se créent sur le
/// Mac. Le suivi de charge doit malgré tout fonctionner : c'est ce qui rend
/// l'onglet Entraînement utile hors de tout plan.
@MainActor
final class TrainingViewModelIOSTests: XCTestCase {
    /// Horloge fixe à 20 h locale, comme les autres suites du Companion.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func run(daysAgo: Int, km: Double, now: Date, calendar: Calendar) -> Workout {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                       duration: 45, durationUnit: "min",
                       totalDistance: km, totalDistanceUnit: "km",
                       totalEnergyBurned: 400, totalEnergyBurnedUnit: "kcal",
                       startDate: start, endDate: start.addingTimeInterval(2700),
                       routeFileName: nil)
    }

    func test_load_withNoRaceGoal_stillProducesTheLoadAssessment() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        _ = try store.insertWorkouts([
            run(daysAgo: 3, km: 10, now: now, calendar: calendar),
            run(daysAgo: 10, km: 10, now: now, calendar: calendar),
            run(daysAgo: 17, km: 10, now: now, calendar: calendar),
            run(daysAgo: 24, km: 10, now: now, calendar: calendar)
        ])

        let viewModel = TrainingViewModel(store: store, now: { now })
        try viewModel.load()

        XCTAssertNil(viewModel.goal, "aucun objectif n'est créé depuis l'iPhone")
        XCTAssertNil(viewModel.plan)
        let assessment = try XCTUnwrap(viewModel.assessment,
                                       "le suivi de charge ne doit pas dépendre d'un objectif")
        XCTAssertGreaterThan(assessment.chronicWeeklyKm, 0)
    }
}
