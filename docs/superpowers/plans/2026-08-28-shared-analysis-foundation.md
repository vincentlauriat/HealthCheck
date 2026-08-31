# Shared Analysis Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make HealthCheck's analysis engines, store, and models compile into both the macOS app and the iOS Companion app, and teach Companion to populate its own local copy of the store from the HealthKit reads it already performs — the prerequisite for an iPhone advisor experience that works without the Mac reachable.

**Architecture:** Extend the existing "shared source directory, no framework" pattern (`HealthCheckShared/`, already used for `ExchangeModels.swift`) to `Analysis/`, `Store/`, `Models/`, and the `CompanionImporter`/`RouteStore` ingestion path — all of it already `Foundation`/`GRDB`-only with zero AppKit dependency. `Companion`'s `SyncEngine` gains a second, independent consumer of each HealthKit delta: alongside the existing push to the Mac, it now also writes into a local `HealthStore` via the same `CompanionImporter.ingest(_:)` the Mac's HTTP handler already uses — one conversion path, two call sites.

**Tech Stack:** Swift 5.9, SwiftUI, GRDB (SQLite), HealthKit, XCTest, XcodeGen (`project.yml` → generated `.xcodeproj`).

**Spec:** `docs/superpowers/specs/2026-08-28-shared-analysis-foundation-design.md` (commit `64ef8ae`) — this plan implements it in full; read both together.

## Global Constraints

- **Precondition for Task 5 only:** the in-flight "offline training-plan cache" work (spec `docs/superpowers/specs/2026-08-25-companion-training-plan-design.md`) must already be merged to `main` before Task 5 starts — it touches `Companion/CompanionApp.swift`, which Task 5 also modifies. Tasks 1-4 do not depend on it and can start immediately. If Task 5 begins and `git status` still shows `Companion/CompanionApp.swift` as modified/uncommitted, STOP and ask Vincent rather than guessing at the merged shape of that file.
- File relocation uses `git mv` (preserves history) — never delete-and-recreate.
- Run `xcodegen generate` after every `project.yml` change or new source file addition, before building.
- macOS test command: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- iOS test command: first `xcrun simctl list devices available` to pick a real simulator name, then `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'` — **without** `CODE_SIGNING_ALLOWED=NO` (it leaves the host app unsigned and Keychain-dependent tests fail with `errSecMissingEntitlement`).
- Per repo convention: any test written specifically to catch a bug must be seen to fail against that bug (or, for new-type TDD, fail to compile) before being accepted as passing.
- Do not touch any file outside this plan's task list — in particular, `Companion/CompanionViewModel.swift`, `Companion/CompanionRootView.swift`, `Companion/Sync/MacClient.swift`, `HealthCheck/Import/CompanionRouter.swift`, `HealthCheck/ViewModels/CompanionViewModel.swift`, `HealthCheck/ViewModels/DashboardViewModel.swift`, `HealthCheck/Views/ContentView.swift`, `HealthCheck/Views/DashboardView.swift`, `HealthCheckShared/ExchangeModels.swift`, `CompanionTests/CompanionViewModelTests.swift`, `CompanionTests/MacClientTests.swift`, `HealthCheckTests/CompanionRouterTests.swift`, `HealthCheckTests/DashboardViewModelTests.swift`, `HealthCheckTests/ExchangeModelsTests.swift`, `HealthCheck/Import/TrainingPlanProvider.swift` are unrelated in-flight work and out of scope for every task below except where Task 5 explicitly reads/edits `Companion/CompanionApp.swift` after confirming it has been merged.

---

## Task 1: Move Analysis/Store/Models/CompanionImporter to HealthCheckShared

**Files:**
- Move: `HealthCheck/Analysis/*.swift` (12 files) → `HealthCheckShared/Analysis/`
- Move: `HealthCheck/Store/HealthStore.swift`, `HealthCheck/Store/SourcePriorityResolver.swift` → `HealthCheckShared/Store/`
- Move: `HealthCheck/Models/*.swift` (5 files) → `HealthCheckShared/Models/`
- Move: `HealthCheck/Import/CompanionImporter.swift`, `HealthCheck/Import/GPXParser.swift` → `HealthCheckShared/Import/`
- Modify: `project.yml`

**Interfaces:**
- Consumes: nothing (no code changes, pure relocation).
- Produces: `CompanionImporter`, `RouteStore`, `GPXParser`, `HealthStore`, `SourcePriorityResolver`, every `Analysis/` engine, and every `Models/` type are now compiled into **both** `HealthCheck` and `HealthCheckCompanion` targets/modules. Later tasks (2, 3, 5) rely on `CompanionImporter`, `HealthStore`, and `RouteStore` being visible from `Companion/Sync/*.swift` and any new `Companion/*.swift` file.

No TDD here — this is a pure relocation with zero behavior change. The existing test suite is the safety net, not a new one.

- [ ] **Step 1: Move the files with `git mv`, preserving history**

```bash
mkdir -p HealthCheckShared/Analysis HealthCheckShared/Store HealthCheckShared/Models HealthCheckShared/Import

git mv HealthCheck/Analysis/BodyCompositionEngine.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/CorrelationEngine.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/DailyAggregator.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/HealthScoreEngine.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/InsightsEngine.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/SessionMatcher.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/SleepAggregator.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/SleepScoreEngine.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/StrainEngine.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/TrainingLoadMonitor.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/TrainingPlanner.swift HealthCheckShared/Analysis/
git mv HealthCheck/Analysis/WorkoutStatsEngine.swift HealthCheckShared/Analysis/

git mv HealthCheck/Store/HealthStore.swift HealthCheckShared/Store/
git mv HealthCheck/Store/SourcePriorityResolver.swift HealthCheckShared/Store/

git mv HealthCheck/Models/HealthRecord.swift HealthCheckShared/Models/
git mv HealthCheck/Models/RaceGoal.swift HealthCheckShared/Models/
git mv HealthCheck/Models/SleepRecord.swift HealthCheckShared/Models/
git mv HealthCheck/Models/TimedHealthValue.swift HealthCheckShared/Models/
git mv HealthCheck/Models/Workout.swift HealthCheckShared/Models/

git mv HealthCheck/Import/CompanionImporter.swift HealthCheckShared/Import/
git mv HealthCheck/Import/GPXParser.swift HealthCheckShared/Import/

rmdir HealthCheck/Analysis HealthCheck/Store HealthCheck/Models 2>/dev/null; true
```

- [ ] **Step 2: Add the GRDB dependency to the `HealthCheckCompanion` target in `project.yml`**

Find this block (the `HealthCheckCompanion` target currently has no `dependencies:` key):

```yaml
  HealthCheckCompanion:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Companion
        excludes:
          - "**/*.entitlements"
          - "Info.plist"
      - path: HealthCheckShared
    settings:
      base:
```

Replace with:

```yaml
  HealthCheckCompanion:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Companion
        excludes:
          - "**/*.entitlements"
          - "Info.plist"
      - path: HealthCheckShared
    dependencies:
      - package: GRDB
        product: GRDB
    settings:
      base:
```

- [ ] **Step 3: Regenerate the Xcode project**

```bash
xcodegen generate
```

- [ ] **Step 4: Verify the macOS test suite passes unchanged**

```bash
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: same pass/fail outcome as before this task — every test that passed before still passes, nothing new fails. If anything fails, it means a moved file had a hidden macOS-only assumption; fix it before continuing (do not skip or silence the failure).

- [ ] **Step 5: Verify the iOS target builds and its existing tests still pass**

```bash
xcrun simctl list devices available
# pick a real simulator name from the output, e.g. "iPhone 16"
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: build succeeds (GRDB now links into the iOS target too), and every existing `CompanionTests` test still passes — nothing in this task touched `Companion/` source, so this is a pure regression check.

- [ ] **Step 6: Commit**

```bash
git add HealthCheckShared/Analysis HealthCheckShared/Store HealthCheckShared/Models HealthCheckShared/Import project.yml
git commit -m "refactor: move Analysis/Store/Models/CompanionImporter into HealthCheckShared"
```

---

## Task 2: SyncEngine gains a local-ingestion port

**Files:**
- Modify: `Companion/Sync/SyncEngine.swift`
- Modify: `CompanionTests/SyncEngineTests.swift`

**Interfaces:**
- Consumes: `CompanionImporter` (from Task 1, now visible in the `HealthCheckCompanion` module — `struct CompanionImporter { func ingest(_ batch: ExchangeBatch) throws -> Int }`), `ExchangeBatch` (unchanged, from `HealthCheckShared/ExchangeModels.swift`).
- Produces: `protocol LocalIngesting { func ingest(_ batch: ExchangeBatch) throws -> Int }`, `extension CompanionImporter: LocalIngesting {}`. `SyncEngine.init` now requires a `localImporter: LocalIngesting` argument. Task 3 (`LocalStore`, `NoOpImporter`) and Task 5 (production wiring) both conform to and consume `LocalIngesting`.

- [ ] **Step 1: Write the failing tests in `CompanionTests/SyncEngineTests.swift`**

Add a fake next to the existing `FakeReader`/`FakePusher`:

```swift
private final class FakeImporter: LocalIngesting {
    var ingestedBatches: [ExchangeBatch] = []
    var shouldThrow = false
    func ingest(_ batch: ExchangeBatch) throws -> Int {
        if shouldThrow { throw NSError(domain: "FakeImporter", code: 1) }
        ingestedBatches.append(batch)
        return batch.records.count + batch.sleep.count + batch.workouts.count
    }
}
```

Add a property and initialize it in `setUpWithError`:

```swift
private var importer: FakeImporter!
```

```swift
    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        anchors = AnchorStore(directory: tempDir)
        reader = FakeReader()
        pusher = FakePusher()
        importer = FakeImporter()
    }
```

Update the private helper to pass it through:

```swift
    private func engine(types: [String]) -> SyncEngine {
        SyncEngine(reader: reader, pusher: pusher, anchors: anchors, localImporter: importer, typeIdentifiers: types)
    }
```

Add four new test methods at the end of the class, before the closing brace:

```swift
    func test_successfulSync_alsoIngestsLocally() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1), record(2)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 7))
        _ = await engine(types: [type]).syncAll()
        XCTAssertEqual(importer.ingestedBatches.count, 1)
        XCTAssertEqual(importer.ingestedBatches[0].records.count, 2)
    }

    func test_pushFailure_stillIngestsLocally() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        pusher.results = [.failure(MacClientError.unreachable)]
        _ = await engine(types: [type]).syncAll()
        XCTAssertEqual(importer.ingestedBatches.count, 1) // insertion locale indépendante de l'échec du push
    }

    func test_localIngestFailure_doesNotBlockPush_orFailSync() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 1))
        importer.shouldThrow = true
        let report = await engine(types: [type]).syncAll()
        XCTAssertEqual(report.pushedSamples, 1)
        XCTAssertTrue(report.failedTypes.isEmpty)
        XCTAssertEqual(pusher.pushedBatches.count, 1)
    }

    func test_localIngestFailure_anchorStillAdvancesOnPushSuccess() async throws {
        let type = "HKQuantityTypeIdentifierStepCount"
        reader.deltas[type] = TypeDelta(typeIdentifier: type, records: [record(1)],
                                        sleep: [], workouts: [], newAnchor: HKQueryAnchor(fromValue: 3))
        importer.shouldThrow = true
        _ = await engine(types: [type]).syncAll()
        // Limite acceptée, spec §8 : l'ancre avance sur l'ack Mac seul, indépendamment
        // du succès de l'insertion locale.
        XCTAssertEqual(anchors.anchor(for: type), HKQueryAnchor(fromValue: 3))
    }
```

- [ ] **Step 2: Run the tests, verify they fail to compile**

```bash
xcrun simctl list devices available
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: **build failure** — `LocalIngesting` does not exist yet, and `SyncEngine.init` does not accept a `localImporter:` argument. This is the red phase.

- [ ] **Step 3: Implement in `Companion/Sync/SyncEngine.swift`**

Add `import os.log` to the top imports:

```swift
import Foundation
import HealthKit
import os.log
```

Add the new protocol and conformance right after the existing `BatchPushing` protocol:

```swift
protocol LocalIngesting {
    func ingest(_ batch: ExchangeBatch) throws -> Int
}

extension CompanionImporter: LocalIngesting {}
```

Add the stored property and update the initializer:

```swift
    private let reader: DeltaReading
    private let pusher: BatchPushing
    private let anchors: AnchorStore
    private let localImporter: LocalIngesting
    private let typeIdentifiers: [String]

    init(reader: DeltaReading, pusher: BatchPushing, anchors: AnchorStore, localImporter: LocalIngesting,
         typeIdentifiers: [String] = SyncEngine.defaultTypes) {
        self.reader = reader
        self.pusher = pusher
        self.anchors = anchors
        self.localImporter = localImporter
        self.typeIdentifiers = typeIdentifiers
    }
```

Update `syncAll()` to build the batch once and ingest it locally, unconditionally, before the push loop:

```swift
    func syncAll() async -> SyncReport {
        var report = SyncReport()
        for type in typeIdentifiers {
            do {
                let delta = try await reader.delta(for: type, since: anchors.anchor(for: type))
                let sampleCount = delta.records.count + delta.sleep.count + delta.workouts.count
                guard sampleCount > 0 else { continue }

                let fullBatch = ExchangeBatch(records: delta.records, sleep: delta.sleep, workouts: delta.workouts)
                do {
                    _ = try localImporter.ingest(fullBatch)
                } catch {
                    os_log(.error, "Insertion locale échouée pour %{public}@: %{public}@",
                           type, String(describing: error))
                }

                let batches = Self.chunk(fullBatch, limit: CompanionProtocol.batchLimit)
                for batch in batches {
                    report.insertedRows += try await pusher.push(batch: batch)
                }
                // Tous les batchs ackés : l'ancre peut avancer.
                try anchors.save(delta.newAnchor, for: type)
                report.pushedSamples += sampleCount
            } catch MacClientError.unauthorized {
                report.needsPairing = true
                report.failedTypes.append(type)
                break // sans jeton valide, les types suivants échoueraient pareil
            } catch {
                report.failedTypes.append(type) // ancre intacte, relivraison au prochain passage
                if let macClientError = error as? MacClientError, case .serverError = macClientError {
                    report.hadServerError = true
                }
            }
        }
        return report
    }
```

- [ ] **Step 4: Run the tests, verify everything passes**

```bash
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: all 4 new tests pass, and every pre-existing `SyncEngineTests` test (chunking, anchor-advance-on-ack, failure isolation between types, unauthorized-stops-sync, empty-delta, server-error-vs-unreachable) still passes unchanged — confirming the existing Mac-push contract was not altered.

- [ ] **Step 5: Commit**

```bash
git add Companion/Sync/SyncEngine.swift CompanionTests/SyncEngineTests.swift
git commit -m "feat(companion): ingest HealthKit deltas locally alongside the Mac push"
```

---

## Task 3: LocalStore — the iPhone's own HealthStore, plus a safe fallback

**Files:**
- Create: `Companion/LocalStore.swift`
- Create: `CompanionTests/LocalStoreTests.swift`

**Interfaces:**
- Consumes: `HealthStore` (`init(path: String) throws`), `RouteStore` (`init(directory: URL?)`), `CompanionImporter` (`init(store: HealthStore, routeStore: RouteStore)`) — all from `HealthCheckShared`, visible since Task 1. `LocalIngesting` protocol from Task 2.
- Produces: `struct LocalStore { let healthStore: HealthStore; let routeStore: RouteStore; let importer: CompanionImporter; init(applicationSupportDirectory: URL? = nil) throws }`. `struct NoOpImporter: LocalIngesting`. Task 5 constructs `LocalStore` and falls back to `NoOpImporter` if it throws.

- [ ] **Step 1: Write the failing tests in `CompanionTests/LocalStoreTests.swift`**

```swift
import XCTest
@testable import HealthCheckCompanion

final class LocalStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_init_createsDirectoryAndUsableStore() throws {
        let local = try LocalStore(applicationSupportDirectory: tempDir)
        let start = Date(timeIntervalSince1970: 1_755_900_000)
        let batch = ExchangeBatch(
            records: [ExchangeRecord(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch",
                device: nil, unit: "count", value: 42, startDate: start,
                endDate: start.addingTimeInterval(300), creationDate: nil)],
            sleep: [], workouts: [])

        XCTAssertEqual(try local.importer.ingest(batch), 1)
        let stored = try local.healthStore.records(
            type: "HKQuantityTypeIdentifierStepCount",
            from: start.addingTimeInterval(-1), to: start.addingTimeInterval(3600))
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.value, 42)
    }

    func test_init_persistsDatabaseFileInGivenDirectory() throws {
        _ = try LocalStore(applicationSupportDirectory: tempDir)
        let dbPath = tempDir.appendingPathComponent("health.sqlite").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    func test_noOpImporter_alwaysReturnsZero_neverThrows() throws {
        let importer = NoOpImporter()
        XCTAssertEqual(try importer.ingest(ExchangeBatch(records: [], sleep: [], workouts: [])), 0)
    }
}
```

- [ ] **Step 2: Run the tests, verify they fail to compile**

```bash
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: build failure — `LocalStore` and `NoOpImporter` do not exist yet.

- [ ] **Step 3: Implement `Companion/LocalStore.swift`**

```swift
import Foundation

/// Store HealthKit local à l'iPhone, alimenté directement par les lectures
/// HealthKit déjà effectuées par HealthKitReaderLive — indépendant du Mac.
/// Spec: docs/superpowers/specs/2026-08-28-shared-analysis-foundation-design.md §5.
struct LocalStore {
    let healthStore: HealthStore
    let routeStore: RouteStore
    let importer: CompanionImporter

    init(applicationSupportDirectory: URL? = nil) throws {
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        healthStore = try HealthStore(path: base.appendingPathComponent("health.sqlite").path)
        routeStore = RouteStore(directory: base.appendingPathComponent("routes", isDirectory: true))
        importer = CompanionImporter(store: healthStore, routeStore: routeStore)
    }
}

/// Repli quand LocalStore ne peut pas s'ouvrir (ex: disque plein) : le push
/// vers le Mac continue, seule l'autonomie locale est perdue pour cette
/// session — spec §8, "ne doit pas régresser la synchro Mac existante".
struct NoOpImporter: LocalIngesting {
    func ingest(_ batch: ExchangeBatch) throws -> Int { 0 }
}
```

- [ ] **Step 4: Run the tests, verify they pass**

```bash
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: all 3 new tests pass, and the whole `CompanionTests` suite (including Task 2's additions) still passes.

- [ ] **Step 5: Commit**

```bash
git add Companion/LocalStore.swift CompanionTests/LocalStoreTests.swift
git commit -m "feat(companion): add LocalStore, the iPhone's own HealthStore"
```

---

## Task 4: Widen the first-sync HealthKit window to 180 days

**Files:**
- Modify: `Companion/Sync/HealthKitReaderLive.swift`
- Create: `CompanionTests/HealthKitReaderLiveTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HealthKitReaderLive.initialWindowDays` becomes `180` (was `30`). New pure static func `HealthKitReaderLive.initialSyncStart(now: Date, calendar: Calendar = .current) -> Date`, extracted so the first-sync window is unit-testable without touching real HealthKit (the rest of `delta(for:since:)` still requires a real `HKHealthStore` and is not unit-tested, consistent with today).

- [ ] **Step 1: Write the failing test in `CompanionTests/HealthKitReaderLiveTests.swift`**

```swift
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
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: build failure — `initialSyncStart` does not exist yet.

- [ ] **Step 3: Implement in `Companion/Sync/HealthKitReaderLive.swift`**

Change the constant and add the extracted static func, right below it:

```swift
    static let initialWindowDays = 180

    static func initialSyncStart(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -initialWindowDays, to: now)!
    }
```

Update the predicate construction inside `delta(for:since:)` to use it:

```swift
        // Prédicat de première synchro seulement ; ensuite l'ancre fait foi.
        let predicate: NSPredicate? = anchor == nil
            ? HKQuery.predicateForSamples(withStart: Self.initialSyncStart(now: now()), end: nil)
            : nil
```

(This replaces the previous inline `Calendar.current.date(byAdding: .day, value: -Self.initialWindowDays, to: now())` expression — same result, now routed through the testable static func.)

- [ ] **Step 4: Run the test, verify it passes**

```bash
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
```

Expected: the new test passes; the whole `CompanionTests` suite still passes (nothing else references `initialWindowDays` or the old inline expression).

- [ ] **Step 5: Commit**

```bash
git add Companion/Sync/HealthKitReaderLive.swift CompanionTests/HealthKitReaderLiveTests.swift
git commit -m "fix(companion): widen first HealthKit sync to 180 days for local advisor use"
```

---

## Task 5: Wire LocalStore into CompanionApp

**Precondition — check before starting anything else in this task:**

```bash
git status --short Companion/CompanionApp.swift
```

Expected: **no output** (file clean, matching `origin/main`). If it shows `M Companion/CompanionApp.swift`, the offline training-plan-cache work (spec `2026-08-25-companion-training-plan-design.md`) has not been merged yet — STOP this task and tell Vincent, do not guess at how to merge your change with in-progress uncommitted work.

**Files:**
- Modify: `Companion/CompanionApp.swift` (exact location to be re-located via `grep`, see Step 1 — its content may have changed since this plan was written, due to the precondition above)

**Interfaces:**
- Consumes: `LocalStore` (Task 3: `init(applicationSupportDirectory: URL? = nil) throws`, `.importer: CompanionImporter`), `NoOpImporter` (Task 3), `SyncEngine.init(reader:pusher:anchors:localImporter:typeIdentifiers:)` (Task 2).
- Produces: nothing new — this is the final wiring task, no other task depends on it.

No TDD here — this is pure object construction with no new decision logic of its own (the fallback logic itself was already tested in Task 3's `NoOpImporter`/`LocalStore` tests). Verification is build + full existing test suite, same as Task 1.

- [ ] **Step 1: Locate the current `SyncEngine` construction**

```bash
grep -n "SyncEngine(" Companion/CompanionApp.swift
```

Read the surrounding ~15 lines of the file at that location (`Read` the file, don't assume the current plan's snapshot still matches). At the time this plan was written, the call site was:

```swift
        let anchors = AnchorStore()
        let engine = SyncEngine(reader: reader, pusher: client, anchors: anchors)
```

- [ ] **Step 2: Add the `LocalStore` construction with a `NoOpImporter` fallback, and pass it into `SyncEngine`**

Immediately before the `SyncEngine(...)` construction found in Step 1, insert:

```swift
        let localImporter: LocalIngesting
        if let localStore = try? LocalStore() {
            localImporter = localStore.importer
        } else {
            localImporter = NoOpImporter()
        }
```

Then add `localImporter: localImporter` as an argument to the existing `SyncEngine(...)` call, keeping every argument already present (`reader:`, `pusher:`, `anchors:`, and any others the merged file may have added) unchanged:

```swift
        let engine = SyncEngine(reader: reader, pusher: client, anchors: anchors, localImporter: localImporter)
```

If the merged file's call site has different or additional arguments than shown above (e.g. from the training-plan-cache work), keep them all — only add `localImporter:`.

- [ ] **Step 3: Regenerate the Xcode project (in case Step 1/2 required no project.yml change, this is a no-op safety check)**

```bash
xcodegen generate
```

- [ ] **Step 4: Build and test both targets**

```bash
xcodebuild build -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
xcrun simctl list devices available   # re-run if the simulator picked earlier is no longer listed
xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<chosen simulator>'
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: both builds succeed, both full test suites pass — this is the final acceptance check for the whole sub-project (spec §4's "both targets build" criterion, now satisfied end-to-end).

- [ ] **Step 5: Commit**

```bash
git add Companion/CompanionApp.swift
git commit -m "feat(companion): wire LocalStore into the sync pipeline"
```

---

## Self-review notes (for the plan author, not a task)

- **Spec coverage:** §4 (file migration) → Task 1. §5 (LocalStore) → Task 3. §6 (SyncEngine local insertion) → Task 2. §7 (180-day backfill) → Task 4. §8 (error handling: local-failure-doesn't-block-push → Task 2 tests; HealthStore-unavailable-falls-back-to-relay-only → Task 3's `NoOpImporter` + Task 5's `try?` wiring). §9 (code structure table) → matches Tasks 1-5's file lists, with `Companion/CompanionApp.swift` added (an omission in the spec's own table, corrected here since `SyncEngine`'s new required parameter makes touching it unavoidable for the app to compile). §11 (known limitations) → carried into Task 2's docstring/comment and Task 5's precondition note.
- **Task ordering fix during authoring:** `LocalIngesting` must be defined before anything can conform to it, so Task 2 (SyncEngine + protocol) now precedes Task 3 (LocalStore + NoOpImporter, both conform to it) — the reverse order would not compile.
- **Type consistency:** `LocalIngesting.ingest(_:) throws -> Int` (Task 2) matches `CompanionImporter.ingest(_:) throws -> Int` (already existing, Task 1 relocation only) and `NoOpImporter.ingest(_:) throws -> Int` (Task 3) exactly — same signature throughout, verified against `HealthCheckTests/CompanionImporterTests.swift`'s existing usage.
