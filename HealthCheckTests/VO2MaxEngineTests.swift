import XCTest
@testable import HealthCheck

final class VO2MaxEngineTests: XCTestCase {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) 09:00")!
    }

    func vo2(_ day: String, _ value: Double) -> HealthRecord {
        HealthRecord(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", device: nil,
                    unit: "mL/min·kg", value: value, startDate: date(day), endDate: date(day),
                    creationDate: date(day))
    }

    // today = 2026-08-23. Recent window = 2026-07-25..2026-08-23 (30 days).
    // Prior window = 2026-04-26..2026-07-24 (the 90 days before that).

    func test_trend_risingWhenDeltaAtOrAboveThreshold() {
        let records = [vo2("2026-08-20", 43.0), vo2("2026-06-01", 40.0)] // delta 3.0
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.verdict, .rising)
        if let trend = trend {
            XCTAssertEqual(trend.recentAverage, 43.0, accuracy: 0.01)
            XCTAssertEqual(trend.priorAverage, 40.0, accuracy: 0.01)
            XCTAssertEqual(trend.delta, 3.0, accuracy: 0.01)
        }
    }

    func test_trend_risingAtExactlyTheThresholdBoundary() {
        let records = [vo2("2026-08-20", 41.0), vo2("2026-06-01", 40.0)] // delta exactly 1.0
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.verdict, .rising)
    }

    func test_trend_stableJustBelowTheThresholdBoundary() {
        let records = [vo2("2026-08-20", 40.9), vo2("2026-06-01", 40.0)] // delta 0.9
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.verdict, .stable)
    }

    func test_trend_decliningWhenDeltaAtOrBelowNegativeThreshold() {
        let records = [vo2("2026-08-20", 38.5), vo2("2026-06-01", 40.0)] // delta -1.5
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.verdict, .declining)
    }

    func test_trend_decliningAtExactlyTheNegativeThresholdBoundary() {
        let records = [vo2("2026-08-20", 39.0), vo2("2026-06-01", 40.0)] // delta exactly -1.0
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.verdict, .declining)
    }

    func test_trend_nilWhenRecentWindowHasNoSample() {
        let records = [vo2("2026-06-01", 40.0)] // only in the prior window
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertNil(trend)
    }

    func test_trend_nilWhenPriorWindowHasNoSample() {
        let records = [vo2("2026-08-20", 43.0)] // only in the recent window
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertNil(trend)
    }

    func test_trend_ignoresRecordsOfOtherTypes() {
        let unrelated = HealthRecord(type: "HKQuantityTypeIdentifierHeartRate", sourceName: "Watch",
                                     device: nil, unit: "count/min", value: 999,
                                     startDate: date("2026-08-20"), endDate: date("2026-08-20"),
                                     creationDate: date("2026-08-20"))
        let records = [unrelated, vo2("2026-08-20", 43.0), vo2("2026-06-01", 40.0)]
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        if let trend = trend {
            XCTAssertEqual(trend.recentAverage, 43.0, accuracy: 0.01) // the 999 sample must not enter the average
        } else {
            XCTFail("trend should not be nil")
        }
    }

    func test_trend_averagesMultipleSamplesPerWindow() {
        let records = [vo2("2026-08-18", 42.0), vo2("2026-08-20", 44.0), vo2("2026-06-01", 40.0)]
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        if let trend = trend {
            XCTAssertEqual(trend.recentAverage, 43.0, accuracy: 0.01) // (42 + 44) / 2
        } else {
            XCTFail("trend should not be nil")
        }
    }

    func test_trend_includesTodayInRecentWindow() {
        // Verify a sample dated exactly today is included in the recent window average.
        let records = [vo2("2026-08-23", 45.0), vo2("2026-06-01", 40.0)]
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        if let trend = trend {
            XCTAssertEqual(trend.recentAverage, 45.0, accuracy: 0.01)
        } else {
            XCTFail("trend should not be nil when today's sample is present")
        }
    }

    func test_stagnationAlert_nilWhenTrendIsNil() {
        XCTAssertNil(VO2MaxEngine.stagnationAlert(trend: nil, chronicKm: 20))
    }

    func test_stagnationAlert_nilWhenRising() {
        let trend = VO2MaxTrend(recentAverage: 43.0, priorAverage: 40.0, delta: 3.0, verdict: .rising)
        XCTAssertNil(VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 20))
    }

    func test_stagnationAlert_nilBelowChronicLoadThreshold() {
        let trend = VO2MaxTrend(recentAverage: 40.0, priorAverage: 40.0, delta: 0.0, verdict: .stable)
        XCTAssertNil(VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 7.9))
    }

    func test_stagnationAlert_infoWhenStableAboveChronicLoadThreshold() {
        let trend = VO2MaxTrend(recentAverage: 40.0, priorAverage: 40.0, delta: 0.0, verdict: .stable)
        let alert = VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 8.0)
        XCTAssertEqual(alert?.severity, .info)
    }

    func test_stagnationAlert_warningWhenDecliningAboveChronicLoadThreshold() {
        let trend = VO2MaxTrend(recentAverage: 38.0, priorAverage: 40.0, delta: -2.0, verdict: .declining)
        let alert = VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 8.0)
        XCTAssertEqual(alert?.severity, .warning)
    }
}
