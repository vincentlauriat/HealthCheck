import XCTest
@testable import HealthCheckCompanion

final class SharedProtocolTests: XCTestCase {
    func test_sharedDTOs_compileAndRoundTrip_oniOS() throws {
        let start = Date(timeIntervalSince1970: 1_755_900_000.123)
        let batch = ExchangeBatch(
            records: [ExchangeRecord(type: "HKQuantityTypeIdentifierRestingHeartRate",
                sourceName: "Watch", device: nil, unit: "count/min", value: 61,
                startDate: start, endDate: start, creationDate: nil)],
            sleep: [], workouts: [])
        let decoded = try ExchangeCoding.decoder.decode(
            ExchangeBatch.self, from: ExchangeCoding.encoder.encode(batch))
        XCTAssertEqual(decoded, batch)
        XCTAssertEqual(CompanionProtocol.serviceType, "_healthcheck._tcp")
        XCTAssertEqual(CompanionProtocol.batchLimit, 500)
    }
}
