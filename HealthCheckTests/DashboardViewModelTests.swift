import XCTest
@testable import HealthCheck

final class DashboardViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    @MainActor
    func test_loadToday_sumsStepsAndDistanceAfterSourceResolution() throws {
        let store = try HealthStore(path: ":memory:")
        // 23:00 aujourd'hui plutôt que l'horloge réelle : ces tests posent leurs
        // données à des heures fixes de la journée (01:00, 14:00). Avec un `now`
        // pris sur l'horloge, ces heures sont dans le futur tant que la journée
        // n'est pas assez avancée, les données sortent de la fenêtre lue et le
        // test échoue — une heure par nuit, tous les jours.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let startOfDay = Calendar.current.startOfDay(for: now)
        let morning = startOfDay.addingTimeInterval(3600)
        let afternoon = startOfDay.addingTimeInterval(3600 * 14)

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "iPhone", value: 100, start: morning),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 90, start: morning),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 200, start: afternoon),
            record(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", sourceName: "Watch", value: 1.5, start: morning),
            record(type: "HKQuantityTypeIdentifierDistanceWalkingRunning", sourceName: "Watch", value: 2.5, start: afternoon)
        ])

        let viewModel = DashboardViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            now: { now }
        )
        try viewModel.loadToday()

        XCTAssertEqual(viewModel.today?.steps, 290, "morning bucket resolves to the Watch value (90), afternoon adds 200")
        XCTAssertEqual(viewModel.today?.distanceKm, 4.0)
    }

    @MainActor
    func test_loadThisWeek_sumsAcrossTheCalendarWeek() throws {
        let store = try HealthStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        // « Maintenant » figé au mercredi 12:00 de la semaine courante, comme
        // le test voisin. Avec un `now` pris sur l'horloge, un lundi fait
        // tomber « plus tôt cette semaine » et « aujourd'hui » sur le même
        // instant : le résolveur de sources voit deux mesures Watch qui se
        // recouvrent, n'en garde qu'une, et la somme attendue s'effondre.
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let now = startOfWeek.addingTimeInterval(2 * 86_400 + 12 * 3600)
        let earlierThisWeek = startOfWeek.addingTimeInterval(3600)
        let today = calendar.startOfDay(for: now).addingTimeInterval(3600)

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 1000, start: earlierThisWeek),
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 500, start: today)
        ])

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), calendar: calendar, now: { now })
        try viewModel.loadThisWeek()

        XCTAssertEqual(viewModel.thisWeek?.steps, 1500)
    }

    @MainActor
    func test_loadThisWeek_comparesToSameElapsedPortionOfPreviousWeek() throws {
        let store = try HealthStore(path: ":memory:")
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        // « Maintenant » figé au mercredi 01:00 : la portion écoulée = 2 j + 1 h.
        let fixedNow = startOfWeek.addingTimeInterval(2 * 86_400 + 3_600)
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek)!

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 2000, start: startOfWeek.addingTimeInterval(3600)),
            // Dans la portion comparable de la semaine passée (lundi 01:00) :
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 5000, start: lastWeekStart.addingTimeInterval(3600)),
            // Hors portion comparable (jeudi de la semaine passée) — doit être exclu :
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 9000, start: lastWeekStart.addingTimeInterval(3 * 86_400))
        ])

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), calendar: calendar, now: { fixedNow })
        try viewModel.loadThisWeek()

        XCTAssertEqual(viewModel.thisWeek?.steps, 2000)
        XCTAssertEqual(viewModel.lastWeek?.steps, 5000, "only the same elapsed portion of last week counts — the Thursday sample must be excluded")
    }

    @MainActor
    func test_load_marksDashboardAsLoaded() throws {
        let store = try HealthStore(path: ":memory:")
        let viewModel = DashboardViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])
        )

        XCTAssertFalse(viewModel.hasLoaded)
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
    }

    @MainActor
    func test_loadWellness_scoresTodayAgainstPersonalBaseline() throws {
        let store = try HealthStore(path: ":memory:")
        // 23:00 aujourd'hui plutôt que l'horloge réelle : ces tests posent leurs
        // données à des heures fixes de la journée (01:00, 14:00). Avec un `now`
        // pris sur l'horloge, ces heures sont dans le futur tant que la journée
        // n'est pas assez avancée, les données sortent de la fenêtre lue et le
        // test échoue — une heure par nuit, tous les jours.
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        // Baseline : 10 jours à 60 bpm, puis 66 bpm aujourd'hui (+10 %).
        var records: [HealthRecord] = (1...10).map { daysAgo in
            record(
                type: "HKQuantityTypeIdentifierRestingHeartRate",
                sourceName: "Watch",
                value: 60,
                start: calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday)!.addingTimeInterval(3600)
            )
        }
        records.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch", value: 66, start: startOfToday.addingTimeInterval(3600)))
        try store.insertRecords(records)

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.loadWellness()

        let hrComponent = viewModel.readiness?.components.first(where: { $0.name == "FC repos" })
        XCTAssertNotNil(hrComponent)
        // +10 % au-dessus de la baseline → 100 − 0,10 × 600 = 40
        XCTAssertEqual(hrComponent!.score, 40, accuracy: 0.01)
    }

    @MainActor
    func test_loadWellness_vo2MaxRising_producesInsightViaTheSharedEngine() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 43.0,
                  start: calendar.date(byAdding: .day, value: -5, to: now)!),
            record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40.0,
                  start: calendar.date(byAdding: .day, value: -60, to: now)!)
        ])

        let viewModel = DashboardViewModel(store: store,
                                           resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
                                           now: { now })
        try viewModel.loadWellness()

        XCTAssertTrue(viewModel.insights.contains { $0.title == "VO₂ max en progression" })
    }
}
