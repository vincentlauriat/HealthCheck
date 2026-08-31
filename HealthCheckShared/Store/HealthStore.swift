import Foundation
import GRDB

enum HealthStoreError: Error {
    /// Le store n'a pas pu s'ouvrir : aucune lecture ni écriture n'est possible.
    case unavailable
}

final class HealthStore {
    private let dbQueue: DatabaseQueue?

    init(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        dbQueue = queue
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS health_record (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    sourceName TEXT NOT NULL,
                    device TEXT,
                    unit TEXT,
                    value REAL NOT NULL,
                    startDate TEXT NOT NULL,
                    endDate TEXT NOT NULL,
                    creationDate TEXT
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_health_record_type_start
                ON health_record(type, startDate)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS workout (
                    id TEXT PRIMARY KEY,
                    activityType TEXT NOT NULL,
                    sourceName TEXT NOT NULL,
                    duration REAL NOT NULL,
                    durationUnit TEXT NOT NULL,
                    totalDistance REAL,
                    totalDistanceUnit TEXT,
                    totalEnergyBurned REAL,
                    totalEnergyBurnedUnit TEXT,
                    startDate TEXT NOT NULL,
                    endDate TEXT NOT NULL,
                    routeFileName TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sleep_record (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    sourceName TEXT NOT NULL,
                    device TEXT,
                    value TEXT NOT NULL,
                    startDate TEXT NOT NULL,
                    endDate TEXT NOT NULL,
                    creationDate TEXT
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_sleep_record_start
                ON sleep_record(startDate)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS race_goal (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    raceDate TEXT NOT NULL,
                    distanceKm REAL NOT NULL,
                    elevationGainM REAL NOT NULL,
                    objective TEXT NOT NULL,
                    createdAt TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS weight_goal (
                    id TEXT PRIMARY KEY,
                    targetWeightKg REAL NOT NULL,
                    targetDate TEXT NOT NULL,
                    createdAt TEXT NOT NULL
                )
                """)
        }
    }

    /// Store inutilisable, sans base sous-jacente : toute lecture ou écriture
    /// lève `HealthStoreError.unavailable`. `HealthCheckApp` s'en sert comme
    /// repli quand la base ne s'ouvre pas, le temps d'afficher son écran
    /// d'erreur — aucune vue ne l'interroge dans ce cas.
    init(unavailable: Void) {
        dbQueue = nil
    }

    private func queue() throws -> DatabaseQueue {
        guard let dbQueue else { throw HealthStoreError.unavailable }
        return dbQueue
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @discardableResult
    func insertRecords(_ records: [HealthRecord], batchSize: Int = 5000) throws -> Int {
        var insertedCount = 0
        for batch in stride(from: 0, to: records.count, by: batchSize).map({ Array(records[$0..<min($0 + batchSize, records.count)]) }) {
            try queue().write { db in
                for record in batch {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO health_record
                            (id, type, sourceName, device, unit, value, startDate, endDate, creationDate)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            record.dedupKey, record.type, record.sourceName, record.device, record.unit,
                            record.value,
                            Self.isoFormatter.string(from: record.startDate),
                            Self.isoFormatter.string(from: record.endDate),
                            record.creationDate.map(Self.isoFormatter.string(from:))
                        ]
                    )
                    if db.changesCount > 0 { insertedCount += 1 }
                }
            }
        }
        return insertedCount
    }

    @discardableResult
    func insertWorkouts(_ workouts: [Workout], batchSize: Int = 5000) throws -> Int {
        var insertedCount = 0
        for batch in stride(from: 0, to: workouts.count, by: batchSize).map({ Array(workouts[$0..<min($0 + batchSize, workouts.count)]) }) {
            try queue().write { db in
                for workout in batch {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO workout
                            (id, activityType, sourceName, duration, durationUnit, totalDistance, totalDistanceUnit,
                             totalEnergyBurned, totalEnergyBurnedUnit, startDate, endDate, routeFileName)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            workout.dedupKey, workout.activityType, workout.sourceName,
                            workout.duration, workout.durationUnit,
                            workout.totalDistance, workout.totalDistanceUnit,
                            workout.totalEnergyBurned, workout.totalEnergyBurnedUnit,
                            Self.isoFormatter.string(from: workout.startDate),
                            Self.isoFormatter.string(from: workout.endDate),
                            workout.routeFileName
                        ]
                    )
                    if db.changesCount > 0 { insertedCount += 1 }
                }
            }
        }
        return insertedCount
    }

    func records(type: String, from: Date, to: Date) throws -> [HealthRecord] {
        try queue().read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM health_record
                    WHERE type = ? AND startDate >= ? AND startDate < ?
                    ORDER BY startDate
                    """,
                arguments: [type, Self.isoFormatter.string(from: from), Self.isoFormatter.string(from: to)]
            )
            return rows.map { row in
                HealthRecord(
                    type: row["type"],
                    sourceName: row["sourceName"],
                    device: row["device"],
                    unit: row["unit"],
                    value: row["value"],
                    startDate: Self.isoFormatter.date(from: row["startDate"])!,
                    endDate: Self.isoFormatter.date(from: row["endDate"])!,
                    creationDate: (row["creationDate"] as String?).flatMap(Self.isoFormatter.date(from:))
                )
            }
        }
    }

    @discardableResult
    func insertSleepRecords(_ records: [SleepRecord], batchSize: Int = 5000) throws -> Int {
        var insertedCount = 0
        for batch in stride(from: 0, to: records.count, by: batchSize).map({ Array(records[$0..<min($0 + batchSize, records.count)]) }) {
            try queue().write { db in
                for record in batch {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO sleep_record
                            (id, type, sourceName, device, value, startDate, endDate, creationDate)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            record.dedupKey, record.type, record.sourceName, record.device, record.value,
                            Self.isoFormatter.string(from: record.startDate),
                            Self.isoFormatter.string(from: record.endDate),
                            record.creationDate.map(Self.isoFormatter.string(from:))
                        ]
                    )
                    if db.changesCount > 0 { insertedCount += 1 }
                }
            }
        }
        return insertedCount
    }

    func workouts(from: Date, to: Date) throws -> [Workout] {
        try queue().read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM workout
                    WHERE startDate >= ? AND startDate < ?
                    ORDER BY startDate
                    """,
                arguments: [Self.isoFormatter.string(from: from), Self.isoFormatter.string(from: to)]
            )
            return rows.map { row in
                Workout(
                    activityType: row["activityType"],
                    sourceName: row["sourceName"],
                    duration: row["duration"],
                    durationUnit: row["durationUnit"],
                    totalDistance: row["totalDistance"],
                    totalDistanceUnit: row["totalDistanceUnit"],
                    totalEnergyBurned: row["totalEnergyBurned"],
                    totalEnergyBurnedUnit: row["totalEnergyBurnedUnit"],
                    startDate: Self.isoFormatter.date(from: row["startDate"])!,
                    endDate: Self.isoFormatter.date(from: row["endDate"])!,
                    routeFileName: row["routeFileName"]
                )
            }
        }
    }

    func averageValue(type: String, from: Date, to: Date) throws -> Double? {
        try queue().read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT AVG(value) FROM health_record WHERE type = ? AND startDate >= ? AND startDate < ?",
                arguments: [type, Self.isoFormatter.string(from: from), Self.isoFormatter.string(from: to)]
            )
        }
    }

    /// Agrégat SQL — indispensable pour les types à très haute fréquence
    /// (FC continue : centaines de milliers de lignes) qu'on ne charge
    /// jamais en mémoire.
    func maxValue(type: String, from: Date, to: Date) throws -> Double? {
        try queue().read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT MAX(value) FROM health_record WHERE type = ? AND startDate >= ? AND startDate < ?",
                arguments: [type, Self.isoFormatter.string(from: from), Self.isoFormatter.string(from: to)]
            )
        }
    }

    func sleepRecords(from: Date, to: Date) throws -> [SleepRecord] {
        try queue().read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM sleep_record
                    WHERE startDate >= ? AND startDate < ?
                    ORDER BY startDate
                    """,
                arguments: [Self.isoFormatter.string(from: from), Self.isoFormatter.string(from: to)]
            )
            return rows.map { row in
                SleepRecord(
                    type: row["type"],
                    sourceName: row["sourceName"],
                    device: row["device"],
                    value: row["value"],
                    startDate: Self.isoFormatter.date(from: row["startDate"])!,
                    endDate: Self.isoFormatter.date(from: row["endDate"])!,
                    creationDate: (row["creationDate"] as String?).flatMap(Self.isoFormatter.date(from:))
                )
            }
        }
    }

    func saveRaceGoal(_ goal: RaceGoal) throws {
        try queue().write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO race_goal
                    (id, name, raceDate, distanceKm, elevationGainM, objective, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [goal.id, goal.name,
                            Self.isoFormatter.string(from: goal.raceDate),
                            goal.distanceKm, goal.elevationGainM,
                            goal.objective.rawValue,
                            Self.isoFormatter.string(from: goal.createdAt)])
        }
    }

    func deleteRaceGoal(id: String) throws {
        try queue().write { db in
            try db.execute(sql: "DELETE FROM race_goal WHERE id = ?", arguments: [id])
        }
    }

    func raceGoals() throws -> [RaceGoal] {
        try queue().read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM race_goal ORDER BY raceDate")
            return rows.compactMap { row in
                guard let raceDate = Self.isoFormatter.date(from: row["raceDate"]),
                      let createdAt = Self.isoFormatter.date(from: row["createdAt"]),
                      let objective = RaceGoal.Objective(rawValue: row["objective"])
                else { return nil }
                return RaceGoal(id: row["id"], name: row["name"], raceDate: raceDate,
                                distanceKm: row["distanceKm"],
                                elevationGainM: row["elevationGainM"],
                                objective: objective, createdAt: createdAt)
            }
        }
    }

    func saveWeightGoal(_ goal: WeightGoal) throws {
        try queue().write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO weight_goal
                    (id, targetWeightKg, targetDate, createdAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [goal.id, goal.targetWeightKg,
                            Self.isoFormatter.string(from: goal.targetDate),
                            Self.isoFormatter.string(from: goal.createdAt)])
        }
    }

    func deleteWeightGoal(id: String) throws {
        try queue().write { db in
            try db.execute(sql: "DELETE FROM weight_goal WHERE id = ?", arguments: [id])
        }
    }

    func weightGoals() throws -> [WeightGoal] {
        try queue().read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM weight_goal ORDER BY targetDate")
            return rows.compactMap { row in
                guard let targetDate = Self.isoFormatter.date(from: row["targetDate"]),
                      let createdAt = Self.isoFormatter.date(from: row["createdAt"])
                else { return nil }
                return WeightGoal(id: row["id"], targetWeightKg: row["targetWeightKg"],
                                  targetDate: targetDate, createdAt: createdAt)
            }
        }
    }
}
