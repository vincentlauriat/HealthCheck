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
