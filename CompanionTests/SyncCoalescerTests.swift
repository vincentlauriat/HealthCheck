import XCTest
@testable import HealthCheckCompanion

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

final class SyncCoalescerTests: XCTestCase {
    func test_concurrentRuns_collapseToOneExecution() async {
        let coalescer = SyncCoalescer()
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await coalescer.run {
                        await counter.increment()
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
            }
        }

        let count = await counter.value
        XCTAssertEqual(count, 1, "10 réveils concurrents doivent se fondre en une seule synchro")
    }

    func test_sequentialRuns_eachExecutesOnceThePreviousOneFinished() async {
        let coalescer = SyncCoalescer()
        let counter = Counter()

        await coalescer.run { await counter.increment() }
        await coalescer.run { await counter.increment() }
        await coalescer.run { await counter.increment() }

        let count = await counter.value
        XCTAssertEqual(count, 3, "des réveils qui ne se chevauchent pas doivent tous s'exécuter")
    }
}
