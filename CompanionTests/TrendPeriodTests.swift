import XCTest
@testable import HealthCheckCompanion

/// Le sélecteur de l'iPhone ne doit proposer que des périodes que la fenêtre
/// HealthKit locale couvre réellement.
final class TrendPeriodTests: XCTestCase {
    /// Horloge fixe à 20 h locale, comme les autres suites du Companion.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    /// Une période exprimée en mois calendaires peut dépasser une fenêtre de
    /// 180 jours fixes : « 6 mois » remonte jusqu'à 184 jours selon le mois de
    /// départ. Cette tolérance absorbe cet écart de calendrier et rien de plus
    /// — « 1 an » dépasse la fenêtre de 185 jours.
    private let calendarSlackDays = 7

    func test_companionCases_stayWithinTheLocalHealthKitWindow() {
        let calendar = Calendar.current
        let now = fixedNow
        let floor = calendar.date(byAdding: .day,
                                  value: -(HealthKitReaderLive.initialWindowDays + calendarSlackDays),
                                  to: now)!

        // Sans ces deux assertions, la suivante serait vraie d'une liste vide.
        XCTAssertEqual(TrendPeriod.companionCases.count, 4)
        XCTAssertTrue(TrendPeriod.companionCases.contains(.sixMonths),
                      "la période la plus longue que l'iPhone puisse honorer")

        for period in TrendPeriod.companionCases {
            XCTAssertGreaterThanOrEqual(
                period.startDate(now: now, calendar: calendar), floor,
                "\(period.label) remonte plus loin que les \(HealthKitReaderLive.initialWindowDays) jours lus dans HealthKit"
            )
        }
    }

    func test_everyCompanionCase_hasALabel() {
        for period in TrendPeriod.companionCases {
            XCTAssertFalse(period.label.isEmpty)
        }
    }
}
