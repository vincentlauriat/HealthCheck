import XCTest
@testable import HealthCheck

final class SessionMatcherTests: XCTestCase {
    private func session(_ kind: SessionKind, km: Double = 0, minutes: Double? = nil) -> PlannedSession {
        PlannedSession(kind: kind, targetKm: km, targetMinutes: minutes,
                       targetClimbM: 0, hrRange: 120...150, note: "")
    }

    private func week(_ sessions: [PlannedSession]) -> PlannedWeek {
        PlannedWeek(monday: Date(timeIntervalSince1970: 0), role: .build,
                    targetKm: sessions.reduce(0) { $0 + $1.targetKm }, sessions: sessions)
    }

    private func run(km: Double, offsetDays: Int = 0) -> Workout {
        let start = Date(timeIntervalSince1970: TimeInterval(offsetDays) * 86_400)
        return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                       duration: 30, durationUnit: "min", totalDistance: km,
                       totalDistanceUnit: "km", totalEnergyBurned: nil,
                       totalEnergyBurnedUnit: nil, startDate: start,
                       endDate: start.addingTimeInterval(1800), routeFileName: nil)
    }

    func test_match_pairsLargestExecutedWithLargestTarget() {
        let w = week([session(.longRun, km: 8), session(.hills, km: 4), session(.baseEndurance, km: 3)])
        let p = SessionMatcher.match(week: w, executed: [run(km: 3.2), run(km: 8.1), run(km: 4.0)])
        XCTAssertEqual(p.matched.map(\.session.kind), [.longRun, .hills, .baseEndurance])
        XCTAssertEqual(p.matched.map { $0.executed?.totalDistance }, [8.1, 4.0, 3.2])
        XCTAssertTrue(p.matched.allSatisfy(\.isDone))
    }

    func test_match_belowSeventyPercentOfTarget_isNotDone() {
        let p = SessionMatcher.match(week: week([session(.longRun, km: 10)]), executed: [run(km: 6.9)])
        XCTAssertFalse(p.matched[0].isDone)
    }

    func test_match_exactlySeventyPercent_isDone() {
        let p = SessionMatcher.match(week: week([session(.longRun, km: 10)]), executed: [run(km: 7.0)])
        XCTAssertTrue(p.matched[0].isDone)
    }

    func test_match_extraRuns_areOffPlanButStillCountInExecutedKm() {
        let p = SessionMatcher.match(week: week([session(.longRun, km: 8)]),
                                     executed: [run(km: 8.0), run(km: 5.0)])
        XCTAssertEqual(p.offPlan.count, 1)
        XCTAssertEqual(p.executedKm, 13.0, accuracy: 0.001)
    }

    func test_match_noExecutedRuns_leavesEverythingUndone() {
        let p = SessionMatcher.match(week: week([session(.longRun, km: 8), session(.hills, km: 4)]),
                                     executed: [])
        XCTAssertTrue(p.matched.allSatisfy { !$0.isDone && $0.executed == nil })
        XCTAssertEqual(p.executedKm, 0)
    }

    func test_match_optionalSession_isDoneOnlyFromALeftoverRun() {
        let w = week([session(.longRun, km: 8), session(.optionalEasy, minutes: 30)])
        let without = SessionMatcher.match(week: w, executed: [run(km: 8.0)])
        XCTAssertFalse(without.matched.first { $0.session.kind == .optionalEasy }!.isDone)
        let with = SessionMatcher.match(week: w, executed: [run(km: 8.0), run(km: 4.0)])
        XCTAssertTrue(with.matched.first { $0.session.kind == .optionalEasy }!.isDone)
        XCTAssertTrue(with.offPlan.isEmpty)
    }

    func test_match_ignoresNonRunningWorkouts() {
        let ride = Workout(activityType: "HKWorkoutActivityTypeCycling", sourceName: "Watch",
                           duration: 60, durationUnit: "min", totalDistance: 30,
                           totalDistanceUnit: "km", totalEnergyBurned: nil,
                           totalEnergyBurnedUnit: nil, startDate: Date(timeIntervalSince1970: 0),
                           endDate: Date(timeIntervalSince1970: 3600), routeFileName: nil)
        let p = SessionMatcher.match(week: week([session(.longRun, km: 8)]), executed: [ride])
        XCTAssertFalse(p.matched[0].isDone)
        XCTAssertEqual(p.executedKm, 0)
    }

    func test_match_preservesTheWeeksSessionOrder() {
        let w = week([session(.longRun, km: 8), session(.hills, km: 4),
                      session(.baseEndurance, km: 3), session(.optionalEasy, minutes: 30)])
        let p = SessionMatcher.match(week: w, executed: [run(km: 4.0)])
        XCTAssertEqual(p.matched.map(\.session.kind), [.longRun, .hills, .baseEndurance, .optionalEasy])
    }
}
