import XCTest
@testable import HealthCheck

final class HealthExportParserTests: XCTestCase {
    private var fixtureURL: URL {
        Bundle(for: Self.self).url(forResource: "sample_export", withExtension: "xml")!
    }

    func test_parse_extractsRecordsAndWorkouts() throws {
        var records: [HealthRecord] = []
        var workouts: [Workout] = []

        try HealthExportParser().parse(
            fileURL: fixtureURL,
            onRecord: { records.append($0) },
            onWorkout: { workouts.append($0) }
        )

        XCTAssertEqual(records.count, 3, "including the unknown future record type, which must not crash the parser")
        XCTAssertEqual(workouts.count, 3)

        let steps = records.filter { $0.type == "HKQuantityTypeIdentifierStepCount" }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.first(where: { $0.sourceName == "iPhone" })?.value, 120)
        XCTAssertEqual(steps.first(where: { $0.sourceName == "Watch" })?.value, 118)

        XCTAssertEqual(workouts.first?.routeFileName, "route_2026-08-18_1.gpx")
    }

    /// Les exports d'Apple ne portent **pas** `totalDistance` ni
    /// `totalEnergyBurned` en attributs de `<Workout>` : relevé le 2026-09-04
    /// sur un export de 1 625 séances, aucune ne les avait. L'information est
    /// dans des enfants `<WorkoutStatistics>`. Ne lire que les attributs
    /// faisait perdre la distance de 98 % des séances en base (1 551 sur
    /// 1 582), que `TrainingPlanner.distanceKm` remplaçait alors par une
    /// estimation à 7 min/km. La fixture d'origine portait ces attributs —
    /// une forme que la production ne produit pas — et c'est pourquoi les
    /// tests passaient.
    func test_parse_readsDistanceAndEnergyFromWorkoutStatistics() throws {
        var workouts: [Workout] = []
        try HealthExportParser().parse(fileURL: fixtureURL, onRecord: { _ in },
                                       onWorkout: { workouts.append($0) })

        let modern = try XCTUnwrap(workouts.first { $0.startDate == date("2026-08-19 08:00:00 +0200") })
        XCTAssertEqual(try XCTUnwrap(modern.totalDistance), 4.20131, accuracy: 0.00001)
        XCTAssertEqual(modern.totalDistanceUnit, "km")
        XCTAssertEqual(try XCTUnwrap(modern.totalEnergyBurned), 301.571, accuracy: 0.001)
        XCTAssertEqual(modern.totalEnergyBurnedUnit, "kcal")
    }

    /// L'ancienne forme doit continuer d'être lue : un export archivé peut
    /// encore la porter, et la garde ci-dessus ne dirait rien si le nouveau
    /// chemin avait remplacé l'ancien au lieu de le compléter.
    func test_parse_stillReadsTheLegacyAttributeForm() throws {
        var workouts: [Workout] = []
        try HealthExportParser().parse(fileURL: fixtureURL, onRecord: { _ in },
                                       onWorkout: { workouts.append($0) })

        let legacy = try XCTUnwrap(workouts.first { $0.startDate == date("2026-08-18 07:30:00 +0200") })
        XCTAssertEqual(legacy.totalDistance, 5)
        XCTAssertEqual(legacy.totalDistanceUnit, "km")
        XCTAssertEqual(legacy.totalEnergyBurned, 300)
    }

    /// La natation est exportée en mètres. L'unité doit voyager avec la
    /// valeur : convertir en silence, ou pire la ranger comme des kilomètres,
    /// donnerait une séance de 1 500 km.
    func test_parse_keepsTheStatisticUnitAsExported() throws {
        var workouts: [Workout] = []
        try HealthExportParser().parse(fileURL: fixtureURL, onRecord: { _ in },
                                       onWorkout: { workouts.append($0) })

        let swim = try XCTUnwrap(workouts.first { $0.activityType == "HKWorkoutActivityTypeSwimming" })
        XCTAssertEqual(swim.totalDistance, 1500)
        XCTAssertEqual(swim.totalDistanceUnit, "m", "surtout pas \"km\"")
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)!
    }

    func test_parse_extractsSleepRecordsSeparatelyFromNumericRecords() throws {
        var records: [HealthRecord] = []
        var sleepRecords: [SleepRecord] = []

        try HealthExportParser().parse(
            fileURL: fixtureURL,
            onRecord: { records.append($0) },
            onWorkout: { _ in },
            onSleepRecord: { sleepRecords.append($0) }
        )

        XCTAssertEqual(records.count, 3, "the sleep record must not land in the numeric records array")
        XCTAssertEqual(sleepRecords.count, 1)
        XCTAssertEqual(sleepRecords.first?.value, "HKCategoryValueSleepAnalysisAsleepCore")
        XCTAssertEqual(sleepRecords.first?.sourceName, "Watch")
    }
}
