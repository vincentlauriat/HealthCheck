import XCTest
@testable import HealthCheck

final class WorkoutStatsEngineTests: XCTestCase {
    /// Calendrier explicite (lundi premier jour, UTC) — jamais `Calendar.current`
    /// ni `Date()`, pour que ces tests ne dépendent ni de la locale ni de
    /// l'horloge de la machine qui les exécute.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // lundi
        return c
    }()

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
        let now = Date(timeIntervalSince1970: 1_755_600_000)  // mardi 2025-08-19
        // Lundis attendus donnés en dur plutôt que recalculés via
        // `calendar.dateInterval`/`TrainingPlanner.monday` — sinon
        // l'attente se recalculerait avec le même mécanisme que le code
        // testé, et ne prouverait rien.
        let thisWeekStart = calendar.date(from: DateComponents(year: 2025, month: 8, day: 18))! // lundi
        let lastWeekStart = calendar.date(from: DateComponents(year: 2025, month: 8, day: 11))! // lundi précédent
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

    /// `weeklyVolumes` doit découper les semaines au lundi, comme
    /// `TrainingPlanner`, quel que soit le `firstWeekday` du calendrier
    /// reçu — pas `calendar.dateInterval(of: .weekOfYear, for:)`, qui suit
    /// la locale. Le fixture est un calendrier explicitement réglé en
    /// dimanche-premier-jour (simule un appareil en anglais US) : c'est le
    /// seul qui peut discriminer, un calendrier français (lundi premier
    /// jour) ferait coïncider les deux découpages et ne prouverait rien.
    func test_weeklyVolumes_anchorsToMondayEvenOnASundayFirstCalendar() {
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.timeZone = TimeZone(identifier: "UTC")!
        sundayFirst.firstWeekday = 1 // dimanche

        func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 9) -> Date {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = dayOfMonth; comps.hour = hour
            return sundayFirst.date(from: comps)!
        }

        let sunday = day(2026, 8, 16)  // dimanche
        let monday = day(2026, 8, 17)  // lundi qui le suit immédiatement

        let workouts = [
            workout("HKWorkoutActivityTypeRunning", start: sunday, minutes: 20),
            workout("HKWorkoutActivityTypeRunning", start: monday, minutes: 30)
        ]

        let volumes = WorkoutStatsEngine.weeklyVolumes(workouts, weeks: 2, now: monday, calendar: sundayFirst)

        XCTAssertEqual(volumes.count, 2)
        // Le dimanche appartient à la semaine du lundi PRÉCÉDENT (08-10),
        // pas à celle du lundi qui le suit (08-17) — même si le calendrier
        // du device dit que dimanche ouvre une nouvelle semaine.
        XCTAssertEqual(volumes[0].weekStart, day(2026, 8, 10, hour: 0))
        XCTAssertEqual(volumes[0].totalMinutes, 20,
                       "le dimanche doit rejoindre la semaine du lundi 08-10, pas celle du 08-17")
        XCTAssertEqual(volumes[1].weekStart, day(2026, 8, 17, hour: 0))
        XCTAssertEqual(volumes[1].totalMinutes, 30)
    }
}
