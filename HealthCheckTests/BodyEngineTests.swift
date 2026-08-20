import XCTest
@testable import HealthCheck

final class BodyCompositionEngineTests: XCTestCase {
    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var day2: Date { day1.addingTimeInterval(86_400) }
    private var day3: Date { day1.addingTimeInterval(2 * 86_400) }

    func test_dailySnapshots_joinsSeriesOnWeightDays() {
        let snapshots = BodyCompositionEngine.dailySnapshots(
            weights: [TrendPoint(date: day1, value: 90), TrendPoint(date: day2, value: 89)],
            fatShares: [TrendPoint(date: day1, value: 0.25)],
            leanMasses: [TrendPoint(date: day1, value: 67.5)],
            bmis: [TrendPoint(date: day1, value: 27.8), TrendPoint(date: day3, value: 27.0)]
        )

        XCTAssertEqual(snapshots.count, 2, "un snapshot par jour de pesée — l'IMC orphelin de day3 est ignoré")
        XCTAssertEqual(snapshots[0].weight, 90)
        XCTAssertEqual(snapshots[0].fatShare, 0.25)
        XCTAssertEqual(snapshots[0].fatMass!, 22.5, accuracy: 0.001, "masse grasse dérivée = poids × part")
        XCTAssertEqual(snapshots[0].leanMass, 67.5)
        XCTAssertEqual(snapshots[0].bmi, 27.8)
        XCTAssertEqual(snapshots[1].weight, 89)
        XCTAssertNil(snapshots[1].fatShare, "pas de % de graisse ce jour-là")
        XCTAssertNil(snapshots[1].fatMass)
    }

    func test_reference_returnsMostRecentSnapshotOnOrBeforeDate() {
        let snapshots = BodyCompositionEngine.dailySnapshots(
            weights: [TrendPoint(date: day1, value: 90), TrendPoint(date: day3, value: 88)],
            fatShares: [], leanMasses: [], bmis: []
        )

        XCTAssertEqual(BodyCompositionEngine.reference(in: snapshots, onOrBefore: day2)?.weight, 90)
        XCTAssertEqual(BodyCompositionEngine.reference(in: snapshots, onOrBefore: day3)?.weight, 88)
        XCTAssertNil(BodyCompositionEngine.reference(in: snapshots, onOrBefore: day1.addingTimeInterval(-1)))
    }
}

final class WeightSankeyTests: XCTestCase {
    func test_weightSankey_fullBreakdownSumsCorrectly() {
        let sankey = BodyCompositionEngine.weightSankey(weight: 90.0, fatMass: 19.0, muscle: 65.0, bone: 3.5)!

        let lean = sankey.nodes.first { $0.id == "maigre" }!
        XCTAssertEqual(lean.kg, 71.0, accuracy: 0.001)
        let others = sankey.nodes.first { $0.id == "autres" }!
        XCTAssertEqual(others.kg, 2.5, accuracy: 0.001, "autres tissus = maigre − muscle − os")

        // Chaque colonne re-somme au poids d'où elle vient.
        let level2 = sankey.nodes.filter { $0.column == 2 }.reduce(0) { $0 + $1.kg }
        XCTAssertEqual(level2, 71.0, accuracy: 0.001)
        let outOfLean = sankey.links.filter { $0.from == "maigre" }.reduce(0) { $0 + $1.kg }
        XCTAssertEqual(outOfLean, 71.0, accuracy: 0.001)
    }

    func test_weightSankey_skipsIncoherentRest() {
        // Muscle Withings mesuré un autre jour que le poids : muscle + os
        // peuvent dépasser la masse maigre — pas de « autres » négatif.
        let sankey = BodyCompositionEngine.weightSankey(weight: 90.0, fatMass: 25.0, muscle: 64.0, bone: 3.5)!
        XCTAssertNil(sankey.nodes.first { $0.id == "autres" })
        XCTAssertEqual(sankey.nodes.filter { $0.column == 2 }.count, 2, "muscle et os restent affichés")
    }

    func test_weightSankey_requiresFatMass_andStopsAtLevelOneWithoutSegments() {
        XCTAssertNil(BodyCompositionEngine.weightSankey(weight: 90, fatMass: nil, muscle: 65, bone: 3.5))

        let simple = BodyCompositionEngine.weightSankey(weight: 90, fatMass: 19, muscle: nil, bone: nil)!
        XCTAssertTrue(simple.nodes.allSatisfy { $0.column < 2 }, "pas de niveau 2 sans muscle ni os")
        XCTAssertEqual(simple.links.count, 2)
    }
}

@MainActor
final class BodyViewModelTests: XCTestCase {
    private func record(_ type: String, value: Double, date: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: "Withings", device: nil, unit: "kg", value: value, startDate: date, endDate: date, creationDate: date)
    }

    func test_load_anchorsDeltasOnLastWeighInNotOnToday() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        // Dernière pesée il y a 60 jours ; référence 30 j avant elle.
        let lastWeighIn = calendar.date(byAdding: .day, value: -60, to: now)!
        let reference = calendar.date(byAdding: .day, value: -32, to: lastWeighIn)!
        try store.insertRecords([
            record("HKQuantityTypeIdentifierBodyMass", value: 91.0, date: reference),
            record("HKQuantityTypeIdentifierBodyMass", value: 89.5, date: lastWeighIn)
        ])

        let viewModel = BodyViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar,
            now: { now }
        )
        try viewModel.load(period: .all)

        XCTAssertEqual(viewModel.latest?.weight, 89.5)
        XCTAssertEqual(viewModel.weightDelta30d!, -1.5, accuracy: 0.001,
                       "le delta 30 j compare la dernière pesée à la pesée d'il y a ≥30 j, même si la balance ne sert plus")
        XCTAssertNil(viewModel.weightDelta1y, "aucune pesée un an avant la dernière")
    }

    func test_load_filtersChartToPeriodButKeepsGlobalLatest() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = calendar.date(byAdding: .month, value: -8, to: now)!
        let recent = calendar.date(byAdding: .day, value: -10, to: now)!
        try store.insertRecords([
            record("HKQuantityTypeIdentifierBodyMass", value: 92.0, date: old),
            record("HKQuantityTypeIdentifierBodyMass", value: 89.0, date: recent)
        ])

        let viewModel = BodyViewModel(
            store: store,
            resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar,
            now: { now }
        )
        try viewModel.load(period: .threeMonths)

        XCTAssertEqual(viewModel.snapshots.count, 1, "le graphique ne montre que la période choisie")
        XCTAssertEqual(viewModel.latest?.weight, 89.0)
    }
}
