import XCTest
@testable import HealthCheck

final class WorkoutStatsEngineTests: XCTestCase {
    private let calendar = Calendar.current

    private func workout(_ type: String, start: Date, minutes: Double, unit: String = "min") -> Workout {
        Workout(
            activityType: type, sourceName: "Watch",
            duration: minutes, durationUnit: unit,
            totalDistance: nil, totalDistanceUnit: nil,
            totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
            startDate: start, endDate: start.addingTimeInterval(minutes * 60),
            routeFileName: nil
        )
    }

    func test_durationMinutes_normalizesUnits() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(WorkoutStatsEngine.durationMinutes(workout("t", start: base, minutes: 34.5)), 34.5)
        XCTAssertEqual(WorkoutStatsEngine.durationMinutes(workout("t", start: base, minutes: 120, unit: "s")), 2)
        XCTAssertEqual(WorkoutStatsEngine.durationMinutes(workout("t", start: base, minutes: 1.5, unit: "hr")), 90)
    }

    /// Une unité non reconnue doit rendre `nil`, jamais une durée fabriquée
    /// en supposant silencieusement des minutes.
    func test_durationMinutes_unrecognisedUnit_returnsNilRatherThanGuessing() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(WorkoutStatsEngine.durationMinutes(workout("t", start: base, minutes: 42, unit: "furlong")))
    }

    func test_label_mapsKnownTypesAndStripsPrefixOtherwise() {
        XCTAssertEqual(WorkoutStatsEngine.label(for: "HKWorkoutActivityTypeRunning"), "Course")
        XCTAssertEqual(WorkoutStatsEngine.label(for: "HKWorkoutActivityTypePickleball"), "Pickleball")
    }

    func test_weeklyVolumes_groupsByWeekAndFillsEmptyWeeks() {
        let now = Date(timeIntervalSince1970: 1_755_600_000)
        let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
        let workouts = [
            workout("HKWorkoutActivityTypeRunning", start: thisWeekStart.addingTimeInterval(3600), minutes: 30),
            workout("HKWorkoutActivityTypeRunning", start: thisWeekStart.addingTimeInterval(90_000), minutes: 20),
            workout("HKWorkoutActivityTypeWalking", start: lastWeekStart.addingTimeInterval(3600), minutes: 45)
        ]

        let volumes = WorkoutStatsEngine.weeklyVolumes(workouts, weeks: 4, now: now, calendar: calendar)

        XCTAssertEqual(volumes.count, 4, "4 semaines demandées, vides comprises")
        XCTAssertEqual(volumes[0].totalMinutes, 0, "semaine sans séance présente mais vide")
        XCTAssertEqual(volumes[2].minutesByActivity["Marche"], 45)
        XCTAssertEqual(volumes[3].minutesByActivity["Course"], 50, "les deux courses de la semaine s'additionnent")
        XCTAssertEqual(volumes[3].weekStart, thisWeekStart)
    }
}
