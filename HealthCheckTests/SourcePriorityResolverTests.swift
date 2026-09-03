import XCTest
@testable import HealthCheck

final class SourcePriorityResolverTests: XCTestCase {
    private func makeRecord(sourceName: String, value: Double, start: Date, end: Date) -> HealthRecord {
        HealthRecord(
            type: "HKQuantityTypeIdentifierStepCount",
            sourceName: sourceName,
            device: nil,
            unit: "count",
            value: value,
            startDate: start,
            endDate: end,
            creationDate: start
        )
    }

    func test_resolve_keepsHigherPrioritySourceOnOverlap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(300)
        let records = [
            makeRecord(sourceName: "iPhone", value: 120, start: start, end: end),
            makeRecord(sourceName: "Watch", value: 118, start: start, end: end)
        ]
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])

        let resolved = resolver.resolve(records)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.sourceName, "Watch")
    }

    /// Les sources réelles portent le nom que l'utilisateur a donné à son
    /// appareil — « Apple Watch de Vincent », « iPhone ☠️ » — jamais le mot nu
    /// « Watch ». Avec une égalité stricte, la priorité ne reconnaissait
    /// aucune source réelle : sur un chevauchement, le premier échantillon
    /// rencontré l'emportait au lieu de la montre. Les autres tests de ce
    /// fichier ne l'ont jamais vu parce qu'ils emploient les mots nus.
    func test_resolve_matchesRealDeviceNames_notOnlyTheBareKeyword() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // L'iPhone commence une seconde plus tôt : il est donc vu en premier,
        // ce qui rend le test déterministe quel que soit l'ordre du tri.
        let records = [
            makeRecord(sourceName: "iPhone ☠️", value: 120,
                       start: start, end: start.addingTimeInterval(300)),
            makeRecord(sourceName: "Apple Watch de Vincent", value: 118,
                       start: start.addingTimeInterval(1), end: start.addingTimeInterval(300))
        ]
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])

        let resolved = resolver.resolve(records)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.sourceName, "Apple Watch de Vincent",
                       "la montre doit l'emporter même quand la source s'appelle « Apple Watch de Vincent »")
    }

    func test_resolve_keepsBothWhenIntervalsDoNotOverlap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeRecord(sourceName: "iPhone", value: 120, start: start, end: start.addingTimeInterval(300)),
            makeRecord(sourceName: "Watch", value: 50, start: start.addingTimeInterval(600), end: start.addingTimeInterval(900))
        ]
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])

        XCTAssertEqual(resolver.resolve(records).count, 2)
    }

    func test_resolve_keepsRecordFromUnlistedSource() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(300)
        let records = [makeRecord(sourceName: "ThirdPartyApp", value: 10, start: start, end: end)]
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])

        XCTAssertEqual(resolver.resolve(records).count, 1)
    }

    private func makeSleepRecord(sourceName: String, start: Date, end: Date) -> SleepRecord {
        SleepRecord(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: sourceName,
            device: nil,
            value: "HKCategoryValueSleepAnalysisAsleepCore",
            startDate: start,
            endDate: end,
            creationDate: start
        )
    }

    func test_resolve_worksGenericallyForSleepRecords() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600)
        let records = [
            makeSleepRecord(sourceName: "iPhone", start: start, end: end),
            makeSleepRecord(sourceName: "Watch", start: start, end: end)
        ]
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])

        let resolved = resolver.resolve(records)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.sourceName, "Watch")
    }
}
