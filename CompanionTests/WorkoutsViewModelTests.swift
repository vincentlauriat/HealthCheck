import XCTest
@testable import HealthCheckCompanion

/// Premiers tests de `WorkoutsViewModel` — manque relevé dans le backlog du
/// 2026-08-24 et jamais comblé.
@MainActor
final class WorkoutsViewModelTests: XCTestCase {
    /// Horloge fixe à 20 h locale, comme les autres suites du Companion.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    /// Un répertoire de traces vide : aucun `routeFileName` n'est posé par ces
    /// fixtures, donc `RouteStore` n'a rien à résoudre — jamais le répertoire
    /// par défaut, qui est celui de l'app.
    private func emptyRouteStore() -> RouteStore {
        RouteStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("routes-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private func workout(daysAgo: Int, km: Double, minutes: Double, kcal: Double,
                         now: Date, calendar: Calendar) -> Workout {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                       duration: minutes, durationUnit: "min",
                       totalDistance: km, totalDistanceUnit: "km",
                       totalEnergyBurned: kcal, totalEnergyBurnedUnit: "kcal",
                       startDate: start, endDate: start.addingTimeInterval(minutes * 60),
                       routeFileName: nil)
    }

    func test_load_listsRecentWorkoutsMostRecentFirst() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        _ = try store.insertWorkouts([
            workout(daysAgo: 1, km: 8, minutes: 40, kcal: 500, now: now, calendar: calendar),
            workout(daysAgo: 5, km: 12, minutes: 65, kcal: 800, now: now, calendar: calendar)
        ])

        let viewModel = WorkoutsViewModel(store: store, routeStore: emptyRouteStore(), now: { now })
        try viewModel.load()

        XCTAssertEqual(viewModel.recentWorkouts.count, 2)
        let first = try XCTUnwrap(viewModel.recentWorkouts.first)
        XCTAssertEqual(first.distanceKm, 8, "la séance la plus récente vient en tête")
        XCTAssertEqual(first.minutes, 40)
        XCTAssertEqual(first.energyKcal, 500)
    }

    /// Une séance dont l'unité de durée n'est pas reconnue ne doit pas
    /// contribuer un nombre fabriqué : `minutes` reste `nil` et le total de la
    /// semaine l'ignore, plutôt que de compter la valeur brute comme des
    /// minutes.
    func test_load_withAnUnknownDurationUnit_reportsNoDurationRatherThanARawNumber() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow
        // Une heure avant `now`, pas la veille : la séance est ainsi dans la
        // semaine courante quel que soit le premier jour de semaine de la
        // locale, sinon `thisWeekMinutes` vaudrait 0 pour la mauvaise raison.
        let start = now.addingTimeInterval(-3600)
        _ = try store.insertWorkouts([
            Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                    duration: 3000, durationUnit: "furlongs",
                    totalDistance: 8, totalDistanceUnit: "km",
                    totalEnergyBurned: 500, totalEnergyBurnedUnit: "kcal",
                    startDate: start, endDate: start.addingTimeInterval(3000),
                    routeFileName: nil)
        ])

        let viewModel = WorkoutsViewModel(store: store, routeStore: emptyRouteStore(), now: { now })
        try viewModel.load()

        let first = try XCTUnwrap(viewModel.recentWorkouts.first)
        XCTAssertNil(first.minutes, "une unité non reconnue ne produit pas de durée")
        XCTAssertEqual(viewModel.thisWeekMinutes, 0,
                       "et elle ne contribue pas 3000 au total de la semaine")
    }

    func test_load_withNoWorkout_leavesEverythingEmptyWithoutThrowing() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = WorkoutsViewModel(store: store, routeStore: emptyRouteStore(), now: { now })
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.recentWorkouts.isEmpty)
        XCTAssertEqual(viewModel.thisWeekCount, 0)
    }
}
