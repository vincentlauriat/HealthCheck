import XCTest
@testable import HealthCheck

final class CorrelationEngineTests: XCTestCase {
    private let calendar = Calendar.current

    private func days(_ count: Int) -> [Date] {
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    func test_pearson_perfectLinearRelationships() {
        let up = (0..<12).map { (Double($0), Double($0) * 2 + 1) }
        XCTAssertEqual(CorrelationEngine.pearson(up)!, 1.0, accuracy: 1e-9)

        let down = (0..<12).map { (Double($0), 10 - Double($0)) }
        XCTAssertEqual(CorrelationEngine.pearson(down)!, -1.0, accuracy: 1e-9)
    }

    func test_pearson_refusesInsufficientOrDegenerateData() {
        let few = (0..<9).map { (Double($0), Double($0)) }
        XCTAssertNil(CorrelationEngine.pearson(few), "9 paires < minimum de 10")

        let constant = (0..<15).map { (Double($0), 42.0) }
        XCTAssertNil(CorrelationEngine.pearson(constant), "variance nulle : r n'est pas défini")
    }

    func test_align_pairsWithLagAndSkipsMissingDays() {
        let d = days(5)
        // x présent aux jours 0,1,2,4 — y présent aux jours 1,2,3.
        let x = [d[0], d[1], d[2], d[4]].enumerated().map { TrendPoint(date: $1, value: Double($0)) }
        let y = [d[1], d[2], d[3]].map { TrendPoint(date: $0, value: 100) }

        let lag1 = CorrelationEngine.align(x: x, y: y, lagDays: 1, calendar: calendar)

        // x(j0)→y(j1) ✓, x(j1)→y(j2) ✓, x(j2)→y(j3) ✓, x(j4)→y(j5) absent.
        XCTAssertEqual(lag1.count, 3)
        XCTAssertEqual(lag1.map(\.day), [d[0], d[1], d[2]], "la paire porte le jour de x")

        let lag0 = CorrelationEngine.align(x: x, y: y, lagDays: 0, calendar: calendar)
        XCTAssertEqual(lag0.count, 2, "seuls j1 et j2 existent des deux côtés")
    }

    func test_strengthLabel_thresholds() {
        XCTAssertEqual(CorrelationEngine.strengthLabel(-0.72), "forte")
        XCTAssertEqual(CorrelationEngine.strengthLabel(0.45), "modérée")
        XCTAssertEqual(CorrelationEngine.strengthLabel(-0.25), "faible")
        XCTAssertEqual(CorrelationEngine.strengthLabel(0.1), "négligeable")
    }
}
