import XCTest
import GRDB
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

    // MARK: - Saison

    func test_saveRaceGoal_roundTripsPriorityAndOverride() throws {
        let store = try HealthStore(path: ":memory:")
        let tuneUp = RaceGoal(id: UUID().uuidString, name: "Route des 4 Châteaux", raceDate: date("2026-11-15"),
                              distanceKm: 18, elevationGainM: 300, objective: .finishComfortable,
                              createdAt: date("2026-10-29"), priority: .tuneUp, peakWeeklyKmOverride: nil)
        let main = RaceGoal(id: UUID().uuidString, name: "Restonica GT20K", raceDate: date("2027-07-09"),
                            distanceKm: 17, elevationGainM: 650, objective: .finishComfortable,
                            createdAt: date("2026-10-29"), priority: .main, peakWeeklyKmOverride: 42.5)
        try store.saveRaceGoal(tuneUp)
        try store.saveRaceGoal(main)
        XCTAssertEqual(try store.raceGoals(), [tuneUp, main])
    }

    /// Une base créée avant la saison n'a ni `priority` ni
    /// `peakWeeklyKmOverride`. L'ouvrir doit ajouter les colonnes sans rien
    /// perdre, et relire l'objectif existant comme une course principale
    /// sans plafond — ce que le moteur faisait déjà de lui.
    func test_legacyRaceGoalTable_isMigratedWithoutLosingTheGoal() throws {
        let path = NSTemporaryDirectory() + "race-goal-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let legacy = try DatabaseQueue(path: path)
            try legacy.write { db in
                try db.execute(sql: """
                    CREATE TABLE race_goal (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, raceDate TEXT NOT NULL,
                        distanceKm REAL NOT NULL, elevationGainM REAL NOT NULL,
                        objective TEXT NOT NULL, createdAt TEXT NOT NULL
                    )
                    """)
                try db.execute(sql: """
                    INSERT INTO race_goal VALUES ('legacy', 'Paris-Versailles', '2026-09-27T08:00:00.000Z',
                                                  16.5, 290, 'finishComfortable', '2026-08-23T07:00:00.000Z')
                    """)
            }
        }

        let store = try HealthStore(path: path)
        let goals = try store.raceGoals()
        XCTAssertEqual(goals.map(\.id), ["legacy"])
        XCTAssertEqual(goals.first?.priority, .main)
        XCTAssertNil(goals.first?.peakWeeklyKmOverride)

        // Rouvrir une base déjà migrée ne doit pas retenter l'ALTER TABLE.
        _ = try HealthStore(path: path)
    }
}
