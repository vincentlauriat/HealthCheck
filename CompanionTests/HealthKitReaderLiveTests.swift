import XCTest
@testable import HealthCheckCompanion

final class HealthKitReaderLiveTests: XCTestCase {
    func test_initialSyncStart_is180DaysBeforeNow() {
        let now = Date(timeIntervalSince1970: 1_756_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let start = HealthKitReaderLive.initialSyncStart(now: now, calendar: calendar)
        let expected = calendar.date(byAdding: .day, value: -180, to: now)!
        XCTAssertEqual(start, expected)
    }
}
