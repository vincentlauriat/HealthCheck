import XCTest
@testable import HealthCheck

final class WithingsMapperTests: XCTestCase {
    func test_records_scalesValuesAndMapsTypes() throws {
        let json = """
        {
          "status": 0,
          "body": {
            "measuregrps": [
              {
                "date": 1755500614,
                "category": 1,
                "measures": [
                  {"value": 89643, "type": 1, "unit": -3},
                  {"value": 25278, "type": 6, "unit": -3},
                  {"value": 6698, "type": 5, "unit": -2},
                  {"value": 55200, "type": 76, "unit": -3},
                  {"value": 42100, "type": 77, "unit": -3},
                  {"value": 3210, "type": 88, "unit": -3},
                  {"value": 9, "type": 170, "unit": 0},
                  {"value": 999, "type": 11, "unit": 0}
                ]
              }
            ]
          }
        }
        """
        let response = try JSONDecoder().decode(WithingsResponse<WithingsMeasureBody>.self, from: Data(json.utf8))
        let records = WithingsMapper.records(from: response.body!.measuregrps)

        XCTAssertEqual(records.count, 7, "le type 11 (FC, non demandé) est ignoré")
        let byType = Dictionary(uniqueKeysWithValues: records.map { ($0.type, $0) })

        XCTAssertEqual(byType["HKQuantityTypeIdentifierBodyMass"]!.value, 89.643, accuracy: 0.0001, "value × 10^unit")
        XCTAssertEqual(byType["HKQuantityTypeIdentifierBodyFatPercentage"]!.value, 0.25278, accuracy: 0.00001,
                       "le % Withings (25,278) est ramené en fraction comme dans l'export Apple Santé")
        XCTAssertEqual(byType["HKQuantityTypeIdentifierLeanBodyMass"]!.value, 66.98, accuracy: 0.0001)
        XCTAssertEqual(byType[WithingsMapper.muscleMassType]!.value, 55.2, accuracy: 0.0001)
        XCTAssertEqual(byType[WithingsMapper.hydrationType]!.value, 42.1, accuracy: 0.0001)
        XCTAssertEqual(byType[WithingsMapper.boneMassType]!.value, 3.21, accuracy: 0.0001)
        XCTAssertEqual(byType[WithingsMapper.visceralFatType]!.value, 9, accuracy: 0.0001)

        let weight = byType["HKQuantityTypeIdentifierBodyMass"]!
        XCTAssertEqual(weight.sourceName, "Withings")
        XCTAssertEqual(weight.startDate, Date(timeIntervalSince1970: 1_755_500_614))
    }

    func test_records_ignoresGoalsCategory() {
        let goal = WithingsMeasureGroup(date: 1_755_500_614, category: 2,
                                        measures: [WithingsMeasure(value: 85000, type: 1, unit: -3)])
        XCTAssertTrue(WithingsMapper.records(from: [goal]).isEmpty, "category 2 = objectif utilisateur, pas une mesure")
    }

    func test_records_areIdempotentThroughStore() throws {
        let store = try HealthStore(path: ":memory:")
        let group = WithingsMeasureGroup(date: 1_755_500_614, category: 1,
                                         measures: [WithingsMeasure(value: 89643, type: 1, unit: -3)])
        let records = WithingsMapper.records(from: [group])

        XCTAssertEqual(try store.insertRecords(records), 1)
        XCTAssertEqual(try store.insertRecords(records), 0, "resynchroniser ne duplique rien")
    }
}

final class WithingsAutoSyncTests: XCTestCase {
    func test_shouldAutoSync_firstLaunchAndStaleness() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertTrue(WithingsViewModel.shouldAutoSync(lastSync: nil, now: now), "jamais synchronisé → oui")
        XCTAssertFalse(WithingsViewModel.shouldAutoSync(lastSync: now.addingTimeInterval(-3600), now: now), "il y a 1 h → non")
        XCTAssertTrue(WithingsViewModel.shouldAutoSync(lastSync: now.addingTimeInterval(-13 * 3600), now: now), "il y a 13 h → oui")
    }
}

final class WithingsCallbackParsingTests: XCTestCase {
    func test_parseCallback_extractsCodeAndState() {
        let request = "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost:8723\r\n"
        let parsed = WithingsClient.parseCallback(requestLine: request)
        XCTAssertEqual(parsed?.code, "abc123")
        XCTAssertEqual(parsed?.state, "xyz")
    }

    func test_parseCallback_rejectsOtherPaths() {
        XCTAssertNil(WithingsClient.parseCallback(requestLine: "GET /favicon.ico HTTP/1.1\r\n"))
        XCTAssertNil(WithingsClient.parseCallback(requestLine: "GET /callback?state=only HTTP/1.1\r\n"))
    }
}
