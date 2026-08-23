import XCTest
@testable import HealthCheck

final class RaceGoalStoreTests: XCTestCase {
    private func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!
    }

    private func goal(_ name: String, _ day: String, km: Double = 17, climb: Double = 400) -> RaceGoal {
        RaceGoal(id: UUID().uuidString, name: name, raceDate: date(day),
                 distanceKm: km, elevationGainM: climb,
                 objective: .finishComfortable, createdAt: date("2026-08-01"))
    }

    func test_saveRaceGoal_roundTripsThroughStore() throws {
        let store = try HealthStore(path: ":memory:")
        let g = goal("Paris-Versailles", "2026-09-27")
        try store.saveRaceGoal(g)
        XCTAssertEqual(try store.raceGoals(), [g])
    }

    func test_saveRaceGoal_sameIdTwice_updatesInsteadOfDuplicating() throws {
        let store = try HealthStore(path: ":memory:")
        let first = goal("Paris-Versailles", "2026-09-27")
        try store.saveRaceGoal(first)
        let updated = RaceGoal(id: first.id, name: "Paris-Versailles 2026",
                               raceDate: first.raceDate, distanceKm: 16.5,
                               elevationGainM: first.elevationGainM,
                               objective: first.objective, createdAt: first.createdAt)
        try store.saveRaceGoal(updated)
        XCTAssertEqual(try store.raceGoals(), [updated])
    }

    func test_deleteRaceGoal_removesOnlyThatGoal() throws {
        let store = try HealthStore(path: ":memory:")
        let a = goal("A", "2026-09-27"), b = goal("B", "2026-10-11")
        try store.saveRaceGoal(a)
        try store.saveRaceGoal(b)
        try store.deleteRaceGoal(id: a.id)
        XCTAssertEqual(try store.raceGoals().map(\.name), ["B"])
    }

    func test_raceGoals_areSortedByRaceDate() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveRaceGoal(goal("Later", "2026-10-11"))
        try store.saveRaceGoal(goal("Sooner", "2026-09-27"))
        XCTAssertEqual(try store.raceGoals().map(\.name), ["Sooner", "Later"])
    }

    func test_active_picksNearestFutureRace_andIgnoresPastOnes() {
        let past = goal("Past", "2026-08-01")
        let soon = goal("Soon", "2026-09-27")
        let later = goal("Later", "2026-10-11")
        XCTAssertEqual(RaceGoal.active(in: [past, later, soon], today: date("2026-08-23"))?.name, "Soon")
    }

    func test_active_raceDayItself_isStillActive() {
        let today = goal("Today", "2026-08-23")
        XCTAssertEqual(RaceGoal.active(in: [today], today: date("2026-08-23"))?.name, "Today")
    }

    func test_active_allRacesPast_isNil() {
        XCTAssertNil(RaceGoal.active(in: [goal("Past", "2026-08-01")], today: date("2026-08-23")))
    }
}
