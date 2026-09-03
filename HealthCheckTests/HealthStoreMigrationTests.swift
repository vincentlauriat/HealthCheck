import XCTest
import GRDB
@testable import HealthCheck

/// La migration qui recalcule les `id` avec la clé normalisée de `DedupKey`.
/// Elle est indispensable au changement de clé : les `id` déjà en base ont été
/// calculés avec l'ancienne, donc sans elle le premier import d'export XML
/// après le changement ne reconnaîtrait plus aucune ligne existante.
final class HealthStoreMigrationTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "migration-\(UUID().uuidString).sqlite"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Crée une base au format d'avant la migration : le schéma est le même,
    /// seuls les `id` diffèrent — ici deux identifiants arbitraires distincts,
    /// exactement ce que produisait l'ancienne clé pour une même mesure.
    private func seedLegacyDatabase(_ rows: [(id: String, value: Double, start: String, end: String, device: String)]) throws {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE health_record (
                    id TEXT PRIMARY KEY, type TEXT NOT NULL, sourceName TEXT NOT NULL,
                    device TEXT, unit TEXT, value REAL NOT NULL,
                    startDate TEXT NOT NULL, endDate TEXT NOT NULL, creationDate TEXT
                )
                """)
            for row in rows {
                try db.execute(sql: """
                    INSERT INTO health_record (id, type, sourceName, device, unit, value, startDate, endDate, creationDate)
                    VALUES (?, 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN', 'Apple Watch de Vincent', ?, 'ms', ?, ?, ?, NULL)
                    """, arguments: [row.id, row.device, row.value, row.start, row.end])
            }
            try db.execute(sql: "PRAGMA user_version = 0")
        }
    }

    func test_migration_mergesTheSameSampleImportedByBothPaths() throws {
        try seedLegacyDatabase([
            (id: "ancienne-cle-export", value: 27.3023, start: "2026-08-16T05:49:20.000Z",
             end: "2026-08-16T05:50:20.000Z", device: "<<HKDevice: 0x7da51ae220>, name:Apple Watch>"),
            (id: "ancienne-cle-synchro", value: 27.30228681394361, start: "2026-08-16T05:49:20.622Z",
             end: "2026-08-16T05:50:20.111Z", device: "")
        ])

        _ = try HealthStore(path: path)

        let queue = try DatabaseQueue(path: path)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, value, startDate FROM health_record")
        }
        XCTAssertEqual(rows.count, 1, "les deux descriptions d'une même mesure doivent fusionner")
        XCTAssertEqual(rows[0]["startDate"], "2026-08-16T05:49:20.622Z",
                       "la ligne conservée est celle de la synchro, seule à porter la milliseconde")
        XCTAssertEqual(rows[0]["value"] as Double, 27.30228681394361, accuracy: 1e-12,
                       "et sa valeur en pleine précision")
        XCTAssertNotEqual(rows[0]["id"], "ancienne-cle-synchro",
                          "l'id doit être recalculé, sinon un import ultérieur ne le reconnaîtra pas")
    }

    func test_migration_recomputesIdsSoALaterImportIsRecognised() throws {
        try seedLegacyDatabase([
            (id: "ancienne-cle-export", value: 27.3023, start: "2026-08-16T05:49:20.000Z",
             end: "2026-08-16T05:50:20.000Z", device: "")
        ])
        let store = try HealthStore(path: path)

        // Réimporter la même mesure, décrite par l'autre chemin : elle ne doit
        // rien insérer. C'est la garantie qui manquait — sans recalcul des id,
        // toute la base serait redoublée au premier import après le changement.
        // 2026-08-16T05:49:20Z, l'instant des lignes semées ci-dessus.
        let second = Date(timeIntervalSince1970: 1_786_859_360)
        let inserted = try store.insertRecords([
            HealthRecord(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                         sourceName: "Apple Watch de Vincent", device: "", unit: "ms",
                         value: 27.30228681394361,
                         startDate: second.addingTimeInterval(0.622),
                         endDate: second.addingTimeInterval(60.111), creationDate: nil)
        ])
        XCTAssertEqual(inserted, 0, "la mesure est déjà en base sous sa clé normalisée")
    }

    func test_migration_keepsSamplesThatAreGenuinelyDistinct() throws {
        try seedLegacyDatabase([
            (id: "a", value: 27.3023, start: "2026-08-16T05:49:20.000Z",
             end: "2026-08-16T05:50:20.000Z", device: ""),
            (id: "b", value: 42.8799, start: "2026-08-16T07:28:27.000Z",
             end: "2026-08-16T07:29:27.000Z", device: "")
        ])

        _ = try HealthStore(path: path)

        let queue = try DatabaseQueue(path: path)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_record")
        }
        XCTAssertEqual(count, 2, "deux mesures distinctes restent deux lignes")
    }

    func test_migration_runsOnlyOnce() throws {
        try seedLegacyDatabase([
            (id: "a", value: 27.3023, start: "2026-08-16T05:49:20.000Z",
             end: "2026-08-16T05:50:20.000Z", device: "")
        ])
        _ = try HealthStore(path: path)
        _ = try HealthStore(path: path)

        let queue = try DatabaseQueue(path: path)
        let version = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") }
        XCTAssertEqual(version, 1, "la migration se marque comme faite et ne rejoue pas")
    }
}
