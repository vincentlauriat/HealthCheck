import XCTest
@testable import HealthCheckCompanion

/// `earliestMeasurement` alimente la mention « Mesures depuis le … » de
/// l'écran Tendances : sur un compte HealthKit récent, une courbe de 6 mois
/// n'en couvre parfois que trois, et l'écran doit le dire.
@MainActor
final class TrendsViewModelIOSTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    /// Horloge fixe à 20 h locale, comme les autres suites du Companion.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func record(_ type: String, _ value: Double, at date: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: "Watch", device: nil, unit: "count/min",
                     value: value, startDate: date, endDate: date, creationDate: date)
    }

    func test_earliestMeasurement_isTheOldestPointAcrossEverySeries() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let oldest = calendar.date(byAdding: .day, value: -100, to: now)!
        let recent = calendar.date(byAdding: .day, value: -10, to: now)!
        // La FC repos est la série la plus courte, la VO2max la plus ancienne :
        // c'est bien la plus ancienne des deux qui doit ressortir.
        _ = try store.insertRecords([
            record("HKQuantityTypeIdentifierRestingHeartRate", 52, at: recent),
            record("HKQuantityTypeIdentifierVO2Max", 48, at: oldest)
        ])

        let viewModel = TrendsViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load(period: .sixMonths)

        let earliest = try XCTUnwrap(viewModel.earliestMeasurement)
        XCTAssertEqual(calendar.startOfDay(for: earliest),
                       calendar.startOfDay(for: oldest),
                       "la mention doit remonter à la plus ancienne mesure, toutes séries confondues")
    }

    func test_earliestMeasurement_withNoDataAtAll_isNil() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = TrendsViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load(period: .sixMonths)

        XCTAssertNil(viewModel.earliestMeasurement,
                     "sans aucune mesure, il n'y a pas de date à annoncer")
    }
}
