import Foundation
import GRDB

enum HealthStoreError: Error {
    /// Le store n'a pas pu s'ouvrir : aucune lecture ni écriture n'est possible.
    case unavailable
}

/// `@unchecked Sendable` : le seul état stocké est une `DatabaseQueue` GRDB,
/// qui sérialise elle-même ses accès entre fils. C'est ce qui autorise
/// `CompanionAdvisorViewModel.refresh()` à lire hors du `MainActor`.
final class HealthStore: @unchecked Sendable {
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
            try Self.migrateDedupKeys(db)
        }
    }

    /// Recalcule les `id` avec la clé normalisée de `DedupKey` et fusionne au
    /// passage les lignes que l'ancienne clé laissait passer en double.
    ///
    /// Cette migration n'est pas un nettoyage optionnel : les `id` déjà en base
    /// ont été calculés avec l'ancienne clé, donc sans elle le premier import
    /// d'export XML après le changement ne reconnaîtrait plus **aucune** ligne
    /// existante et rendrait la base entièrement en double.
    ///
    /// Ligne conservée dans chaque groupe : celle qui porte le plus
    /// d'information — la trace GPX d'abord pour une séance, puis
    /// l'horodatage à la milliseconde, que seule la synchro iPhone fournit.
    private static func migrateDedupKeys(_ db: Database) throws {
        guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 0 else { return }

        // La clé est un SHA-256 calculé en Swift : on l'expose à SQLite plutôt
        // que de matérialiser 1,8 million de modèles pour les réinsérer. Les
        // dates arrivent sous leur forme stockée (`2026-08-16T05:49:20.622Z`),
        // dont les 19 premiers caractères sont déjà la seconde en UTC.
        func text(_ value: DatabaseValue) -> String { String.fromDatabaseValue(value) ?? "" }
        func second(_ value: DatabaseValue) -> String { String(text(value).prefix(19)) + "Z" }
        func number(_ value: DatabaseValue) -> String {
            DedupKey.rounded(Double.fromDatabaseValue(value) ?? 0)
        }

        let recordKey = DatabaseFunction("dedup_key_record", argumentCount: 6, pure: true) { values in
            DedupKey.digest([text(values[0]), text(values[1]), text(values[2]),
                             number(values[3]), second(values[4]), second(values[5])])
        }
        let workoutKey = DatabaseFunction("dedup_key_workout", argumentCount: 5, pure: true) { values in
            DedupKey.digest([text(values[0]), text(values[1]), number(values[2]),
                             second(values[3]), second(values[4])])
        }
        let sleepKey = DatabaseFunction("dedup_key_sleep", argumentCount: 5, pure: true) { values in
            DedupKey.digest([text(values[0]), text(values[1]), text(values[2]),
                             second(values[3]), second(values[4])])
        }
        db.add(function: recordKey)
        db.add(function: workoutKey)
        db.add(function: sleepKey)
        defer {
            db.remove(function: recordKey)
            db.remove(function: workoutKey)
            db.remove(function: sleepKey)
        }

        try db.execute(sql: """
            CREATE TABLE health_record_migrated (
                id TEXT PRIMARY KEY, type TEXT NOT NULL, sourceName TEXT NOT NULL,
                device TEXT, unit TEXT, value REAL NOT NULL,
                startDate TEXT NOT NULL, endDate TEXT NOT NULL, creationDate TEXT
            )
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO health_record_migrated
            SELECT dedup_key_record(type, sourceName, IFNULL(unit, ''), value, startDate, endDate),
                   type, sourceName, device, unit, value, startDate, endDate, creationDate
            FROM health_record
            ORDER BY (startDate LIKE '%.000Z')
            """)
        try db.execute(sql: "DROP TABLE health_record")
        try db.execute(sql: "ALTER TABLE health_record_migrated RENAME TO health_record")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_health_record_type_start
            ON health_record(type, startDate)
            """)

        try db.execute(sql: """
            CREATE TABLE workout_migrated (
                id TEXT PRIMARY KEY, activityType TEXT NOT NULL, sourceName TEXT NOT NULL,
                duration REAL NOT NULL, durationUnit TEXT NOT NULL,
                totalDistance REAL, totalDistanceUnit TEXT,
                totalEnergyBurned REAL, totalEnergyBurnedUnit TEXT,
                startDate TEXT NOT NULL, endDate TEXT NOT NULL, routeFileName TEXT
            )
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO workout_migrated
            SELECT dedup_key_workout(activityType, sourceName, duration, startDate, endDate),
                   activityType, sourceName, duration, durationUnit,
                   totalDistance, totalDistanceUnit, totalEnergyBurned, totalEnergyBurnedUnit,
                   startDate, endDate, routeFileName
            FROM workout
            ORDER BY (routeFileName IS NULL), (startDate LIKE '%.000Z')
            """)
        try db.execute(sql: "DROP TABLE workout")
        try db.execute(sql: "ALTER TABLE workout_migrated RENAME TO workout")

        try db.execute(sql: """
            CREATE TABLE sleep_record_migrated (
                id TEXT PRIMARY KEY, type TEXT NOT NULL, sourceName TEXT NOT NULL,
                device TEXT, value TEXT NOT NULL,
                startDate TEXT NOT NULL, endDate TEXT NOT NULL, creationDate TEXT
            )
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO sleep_record_migrated
            SELECT dedup_key_sleep(type, sourceName, value, startDate, endDate),
                   type, sourceName, device, value, startDate, endDate, creationDate
            FROM sleep_record
            ORDER BY (startDate LIKE '%.000Z')
            """)
        try db.execute(sql: "DROP TABLE sleep_record")
        try db.execute(sql: "ALTER TABLE sleep_record_migrated RENAME TO sleep_record")
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_sleep_record_start
            ON sleep_record(startDate)
            """)

        try db.execute(sql: "PRAGMA user_version = 1")
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
    /// Insère les séances inconnues et **complète** celles déjà connues dont
    /// il manquait la distance, l'énergie ou la trace GPS.
    ///
    /// Le complément n'est pas un raffinement : la clé de dédoublonnage d'une
    /// séance ne dépend ni de la distance ni de l'énergie (§`Workout.dedupKey`),
    /// donc un `INSERT OR IGNORE` seul laissait à jamais vides les 1 551
    /// séances importées avant le 2026-09-04 — date à laquelle le parseur a
    /// appris à lire `<WorkoutStatistics>`. Sans ce complément, corriger le
    /// parseur n'aurait rien réparé du passé.
    ///
    /// `COALESCE` dans ce sens précis — l'existant d'abord — garantit qu'un
    /// import ne peut qu'ajouter de l'information, jamais en effacer.
    func insertWorkouts(_ workouts: [Workout], batchSize: Int = 5000) throws -> (inserted: Int, enriched: Int) {
        var insertedCount = 0
        var enrichedCount = 0
        for batch in stride(from: 0, to: workouts.count, by: batchSize).map({ Array(workouts[$0..<min($0 + batchSize, workouts.count)]) }) {
            try queue().write { db in
                for workout in batch {
                    // D'abord le complément, pour que `changesCount` ci-dessous
                    // ne compte que de vraies insertions.
                    try db.execute(
                        sql: """
                            UPDATE workout SET
                                totalDistance = COALESCE(totalDistance, ?),
                                totalDistanceUnit = COALESCE(totalDistanceUnit, ?),
                                totalEnergyBurned = COALESCE(totalEnergyBurned, ?),
                                totalEnergyBurnedUnit = COALESCE(totalEnergyBurnedUnit, ?),
                                routeFileName = COALESCE(routeFileName, ?)
                            WHERE id = ?
                              AND ((totalDistance IS NULL AND ? IS NOT NULL)
                                OR (totalEnergyBurned IS NULL AND ? IS NOT NULL)
                                OR (routeFileName IS NULL AND ? IS NOT NULL))
                            """,
                        arguments: [
                            workout.totalDistance, workout.totalDistanceUnit,
                            workout.totalEnergyBurned, workout.totalEnergyBurnedUnit,
                            workout.routeFileName, workout.dedupKey,
                            workout.totalDistance, workout.totalEnergyBurned, workout.routeFileName
                        ]
                    )
                    enrichedCount += db.changesCount

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
        return (insertedCount, enrichedCount)
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
