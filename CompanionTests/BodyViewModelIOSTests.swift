import XCTest
@testable import HealthCheckCompanion

/// L'écran Corps de l'iPhone affiche la **date** de la dernière pesée en clair.
/// La synchro Withings → Santé est en panne depuis le 18 juin 2026 (spec §6) :
/// une pesée bien plus ancienne que la période affichée est le cas normal, pas
/// l'exception, et elle ne doit pas disparaître avec le sélecteur de période.
@MainActor
final class BodyViewModelIOSTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    /// Horloge fixe à 20 h locale, comme les autres suites du Companion.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func weighIn(_ kg: Double, at date: Date) -> HealthRecord {
        HealthRecord(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", device: nil,
                     unit: "kg", value: kg, startDate: date, endDate: date, creationDate: date)
    }

    func test_latest_isTheMostRecentWeighIn_evenOutsideTheDisplayedPeriod() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let longAgo = calendar.date(byAdding: .day, value: -200, to: now)!
        _ = try store.insertRecords([weighIn(88.5, at: longAgo)])

        let viewModel = BodyViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load(period: .oneMonth)

        XCTAssertTrue(viewModel.snapshots.isEmpty,
                      "rien à tracer sur un mois : la pesée est bien hors période")
        let latest = try XCTUnwrap(viewModel.latest,
                                   "la dernière pesée doit survivre au sélecteur de période")
        XCTAssertEqual(calendar.startOfDay(for: latest.day), calendar.startOfDay(for: longAgo))
        XCTAssertEqual(latest.weight, 88.5, accuracy: 0.0001)
    }

    /// Sur iPhone rien n'écrit les mesures Withings : la composition corporelle
    /// et le Sankey n'ont pas de données, et c'est l'attendu (spec §6).
    func test_withingsOnlyMeasures_stayEmptyOnTheCompanion() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow
        _ = try store.insertRecords([weighIn(88.5, at: now.addingTimeInterval(-3600))])

        let viewModel = BodyViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load(period: .sixMonths)

        XCTAssertNotNil(viewModel.latest, "le poids, lui, est bien là")
        XCTAssertNil(viewModel.latestMuscleMass)
        XCTAssertNil(viewModel.latestHydration)
        XCTAssertNil(viewModel.latestBoneMass)
        XCTAssertNil(viewModel.latestVisceralFat)
        XCTAssertNil(viewModel.weightSankey, "pas de Sankey sans % de graisse ni masses Withings")
    }
}
