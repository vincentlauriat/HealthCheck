import XCTest
@testable import HealthCheck

final class WeightGoalStoreTests: XCTestCase {
    private func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!
    }

    private func goal(_ targetKg: Double, _ day: String) -> WeightGoal {
        WeightGoal(id: UUID().uuidString, targetWeightKg: targetKg, targetDate: date(day),
                  createdAt: date("2026-08-01"))
    }

    func test_saveWeightGoal_roundTripsThroughStore() throws {
        let store = try HealthStore(path: ":memory:")
        let g = goal(70.0, "2026-12-25")
        try store.saveWeightGoal(g)
        XCTAssertEqual(try store.weightGoals(), [g])
    }

    func test_saveWeightGoal_sameIdTwice_updatesInsteadOfDuplicating() throws {
        let store = try HealthStore(path: ":memory:")
        let first = goal(70.0, "2026-12-25")
        try store.saveWeightGoal(first)
        let updated = WeightGoal(id: first.id, targetWeightKg: 68.0,
                                 targetDate: first.targetDate, createdAt: first.createdAt)
        try store.saveWeightGoal(updated)
        XCTAssertEqual(try store.weightGoals(), [updated])
    }

    func test_deleteWeightGoal_removesOnlyThatGoal() throws {
        let store = try HealthStore(path: ":memory:")
        let a = goal(70.0, "2026-09-27"), b = goal(65.0, "2026-10-11")
        try store.saveWeightGoal(a)
        try store.saveWeightGoal(b)
        try store.deleteWeightGoal(id: a.id)
        XCTAssertEqual(try store.weightGoals().map(\.targetWeightKg), [65.0])
    }

    func test_weightGoals_areSortedByTargetDate() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveWeightGoal(goal(65.0, "2026-10-11"))
        try store.saveWeightGoal(goal(70.0, "2026-09-27"))
        XCTAssertEqual(try store.weightGoals().map(\.targetWeightKg), [70.0, 65.0])
    }

    func test_active_picksNearestFutureTargetDate_andIgnoresPastOnes() {
        let past = goal(72.0, "2026-08-01")
        let soon = goal(70.0, "2026-09-27")
        let later = goal(65.0, "2026-10-11")
        XCTAssertEqual(WeightGoal.active(in: [past, later, soon], today: date("2026-08-23"))?.targetWeightKg, 70.0)
    }

    func test_active_targetDateItself_isStillActive() {
        let today = goal(70.0, "2026-08-23")
        XCTAssertEqual(WeightGoal.active(in: [today], today: date("2026-08-23"))?.targetWeightKg, 70.0)
    }

    func test_active_allTargetsPast_isNil() {
        XCTAssertNil(WeightGoal.active(in: [goal(70.0, "2026-08-01")], today: date("2026-08-23")))
    }
}
