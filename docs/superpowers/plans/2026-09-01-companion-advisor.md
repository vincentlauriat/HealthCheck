# Companion Advisor Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `HealthCheckCompanion` (iPhone) its own "Conseils" tab — readiness score, "Conseil du jour", and VO2max trend — computed entirely from the app's own local `HealthStore`, independent of the Mac being reachable.

**Architecture:** A new `CompanionAdvisorViewModel` replicates `DashboardViewModel.loadWellness()` (macOS) against Companion's local store, minus weight and activity insights (out of scope). A new `CompanionAdvisorView` renders it. `CompanionRootView` becomes a 2-tab `TabView` shell; its current single-screen content (pairing/sync/training-plan) moves unchanged into a new `CompanionSyncView`.

**Tech Stack:** Swift, XCTest, XcodeGen-generated Xcode project, GRDB-backed `HealthStore` (shared with macOS via `HealthCheckShared/`).

**Spec:** `docs/superpowers/specs/2026-08-31-companion-advisor-design.md`

## Global Constraints

- No new engine, no new threshold — pure composition of `HealthScoreEngine`, `TrainingLoadMonitor`, `VO2MaxEngine`, `DailyAdviceEngine`, all already in `HealthCheckShared/Analysis/` and already compiling into the `HealthCheckCompanion` target.
- **No weight, anywhere in this plan.** `WeightEngine` is not called, no `HKQuantityTypeIdentifierBodyMass` read is added. Confirmed with Vincent (spec, "Correction post-approbation") against the existing rule in `CompanionTests/HKMapperTests.swift:test_unknownQuantityType_isDropped` ("balance = territoire Withings") — do not "fix" that test's `bodyMass` case, it is correct as written and must keep passing unchanged.
- `TrainingLoadMonitor.assess(...)` is always called with `plan: nil` — no bridging to the cached training plan.
- No file under `HealthCheck/` (macOS) or `HealthCheckShared/` (shared) is touched by this plan. Every change is in `Companion/` or `CompanionTests/`.
- `xcodegen generate` after adding a new source file, before the first build referencing it. Never `git add` the generated `HealthCheck.xcodeproj`.
- iOS test command: `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<a simulator from the list below>'` — **without** `CODE_SIGNING_ALLOWED=NO` (leaving the host app unsigned blocks Keychain-dependent tests already in this target). List available simulators first: `xcrun simctl list devices available`. At plan-writing time, `iPhone 17 Pro`, `iPhone 17 Pro Max`, `iPhone 17e`, `iPhone Air`, `iPhone 17` were all available — pick whichever the simulator list shows when you run the command, don't assume the list hasn't changed.
- Any test written specifically to catch a bug must be seen to fail against that exact bug before being accepted (repo convention) — for new logic, the red step of TDD (compile failure, then the correct assertion failure) satisfies this.

---

### Task 1: CompanionAdvisorViewModel + local store wiring

**Files:**
- Create: `Companion/CompanionAdvisorViewModel.swift`
- Modify: `Companion/CompanionApp.swift:14-34` (whole `init()`) and `:12` (new stored property)
- Test: `CompanionTests/CompanionAdvisorViewModelTests.swift`

**Interfaces:**
- Consumes: `HealthStore` (`HealthCheckShared/Store/HealthStore.swift`, already compiles into this target — `init(path:) throws`, `init(unavailable: Void)`, `records(type:from:to:) throws -> [HealthRecord]`, `sleepRecords(from:to:) throws -> [SleepRecord]`, `workouts(from:to:) throws -> [Workout]`); `SourcePriorityResolver.resolve(_:)`; `DailyAggregator.averages(_:calendar:)`/`.totals(_:calendar:)`; `SleepAggregator.nightlyHours(_:calendar:)`; `HealthScoreEngine.readiness(sleep:restingHeartRate:hrv:activity:)`, `.sleepScore`, `.restingHeartRateScore`, `.hrvScore`, `.activityBalanceScore`; `VO2MaxEngine.vo2MaxType`, `.trend(records:today:calendar:)`, `.stagnationAlert(trend:chronicKm:)`; `TrainingLoadMonitor.assess(history:plan:readiness:today:calendar:)`; `DailyAdviceEngine.advise(readiness:loadAlerts:vo2MaxAlert:weightAlert:)`; `LocalStore` (`Companion/LocalStore.swift`, `healthStore`/`importer` properties, `init() throws`).
- Produces: `CompanionAdvisorViewModel` — `@Published private(set) var readiness: ReadinessScore?`, `.dailyAdvice: DailyAdvice?`, `.vo2Trend: VO2MaxTrend?`, `.hasLoaded: Bool`, `.storeUnavailable: Bool`; `init(store: HealthStore, resolver: SourcePriorityResolver, calendar: Calendar = .current, now: @escaping () -> Date = Date.init)`; `func refresh()` (non-throwing) — consumed by Task 2 (`CompanionAdvisorView`) and Task 3 (`CompanionApp`, `CompanionRootView`).

- [ ] **Step 1: Write the failing tests**

Create `CompanionTests/CompanionAdvisorViewModelTests.swift`:

```swift
import XCTest
@testable import HealthCheckCompanion

@MainActor
final class CompanionAdvisorViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    // Baseline dégradée : FC repos +10 % vs. 10 jours à 60 bpm -> readiness
    // "Récupération conseillée" -> palier .repos. Fixture identique à celle
    // du sous-projet 3 (weight-advisor), déjà vérifiée produire ce résultat.
    private func insertDegradedRestingHRHistory(_ store: HealthStore, now: Date, calendar: Calendar) throws {
        var records: [HealthRecord] = (1...10).map { daysAgo in
            record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch", value: 60,
                  start: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600))
        }
        records.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch",
                              value: 66, start: calendar.startOfDay(for: now).addingTimeInterval(3600)))
        try store.insertRecords(records)
    }

    func test_refresh_computesReadinessAndDailyAdviceFromLocalStore() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertDegradedRestingHRHistory(store, now: now, calendar: calendar)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertEqual(viewModel.readiness?.label, "Récupération conseillée")
        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_refresh_vo2MaxTrendComputedFromLocalStore() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        // Fenêtre récente (30j) à 45, fenêtre antérieure (30-120j) à 40 ->
        // delta +5, largement au-dessus de meaningfulDeltaThreshold (1.0) -> .rising.
        var records: [HealthRecord] = []
        for daysAgo in stride(from: 5, through: 25, by: 10) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 45,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        for daysAgo in stride(from: 45, through: 105, by: 20) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        try store.insertRecords(records)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        viewModel.refresh()

        XCTAssertEqual(viewModel.vo2Trend?.verdict, .rising)
    }

    func test_refresh_emptyStore_readinessAndAdviceAreNilWithoutError() throws {
        let store = try HealthStore(path: ":memory:")
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertNil(viewModel.readiness)
        XCTAssertNil(viewModel.dailyAdvice)
        XCTAssertNil(viewModel.vo2Trend)
    }

    func test_refresh_storeUnavailable_setsFlagWithoutThrowing() {
        let store = HealthStore(unavailable: ())
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.storeUnavailable)
        XCTAssertNil(viewModel.readiness)
        XCTAssertNil(viewModel.dailyAdvice)
    }

    // Non-goal de la spec §2 : même si des données de poids existent en
    // base (import antérieur, scénario futur), cet écran ne doit JAMAIS
    // faire remonter d'alerte de poids. Rythme de -1.5 kg/semaine, celui-là
    // même qui déclenche WeightEngine.safetyAlert(.warning) côté sous-projet
    // 3 (weight-advisor) — falsifiable : ce test échouerait si un futur
    // lecteur câblait WeightEngine par erreur sur cet écran.
    func test_refresh_neverSurfacesAWeightAlertEvenIfWeightDataExistsLocally() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertDegradedRestingHRHistory(store, now: now, calendar: calendar)
        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 100,
                  start: calendar.date(byAdding: .day, value: -20, to: now)!),
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 97,
                  start: calendar.date(byAdding: .day, value: -5, to: now)!)
        ])

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        viewModel.refresh()

        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.",
                      "aucune alerte de poids ne doit jamais apparaître sur cet écran (non-goal spec §2), même si des données de poids existent en base")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

List simulators first: `xcrun simctl list devices available`.
Run: `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:CompanionTests/CompanionAdvisorViewModelTests`
Expected: FAIL to compile — `CompanionAdvisorViewModel` doesn't exist yet.

- [ ] **Step 3: Create CompanionAdvisorViewModel**

Create `Companion/CompanionAdvisorViewModel.swift`:

```swift
import Foundation

/// Réplique `DashboardViewModel.loadWellness()` (macOS) contre le
/// `HealthStore` local du Companion — jamais celui du Mac. Sans les
/// insights d'activité/pas (hors périmètre de cet écran) et sans le poids
/// (spec §2 : « balance = territoire Withings », le poids reste exclusif
/// au Mac).
@MainActor
final class CompanionAdvisorViewModel: ObservableObject {
    @Published private(set) var readiness: ReadinessScore?
    @Published private(set) var dailyAdvice: DailyAdvice?
    @Published private(set) var vo2Trend: VO2MaxTrend?
    @Published private(set) var hasLoaded = false
    @Published private(set) var storeUnavailable = false

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, resolver: SourcePriorityResolver,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
    }

    /// Ne lève jamais — contrairement à `DashboardViewModel.load()`, un
    /// store indisponible est un état normal de cet écran (§`storeUnavailable`),
    /// pas une raison d'empêcher toute la scène de démarrer comme sur le Mac.
    func refresh() {
        hasLoaded = true
        do {
            try compute()
            storeUnavailable = false
        } catch {
            storeUnavailable = true
            readiness = nil
            dailyAdvice = nil
            vo2Trend = nil
        }
    }

    private func compute() throws {
        let end = now()
        guard
            let d30 = calendar.date(byAdding: .day, value: -30, to: end),
            let d120 = calendar.date(byAdding: .day, value: -120, to: end)
        else { return }
        let startOfToday = calendar.startOfDay(for: end)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let hrDaily = try dailyAverages(type: "HKQuantityTypeIdentifierRestingHeartRate", from: d30, to: end)
        let hrvDaily = try dailyAverages(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", from: d30, to: end)
        let energyDaily = DailyAggregator.totals(
            resolver.resolve(try store.records(type: "HKQuantityTypeIdentifierActiveEnergyBurned", from: d30, to: end)),
            calendar: calendar
        )
        let sleepNights = SleepAggregator.nightlyHours(
            resolver.resolve(try store.sleepRecords(from: d30, to: end)),
            calendar: calendar
        )

        // « Aujourd'hui » = dernier point s'il date bien d'aujourd'hui
        // (d'hier pour le sommeil) ; la baseline = tous les points
        // précédents. Identique à DashboardViewModel.loadWellness().
        func split(_ points: [TrendPoint], latestNoOlderThan cutoff: Date) -> (latest: Double?, baseline: [Double]) {
            guard let last = points.last else { return (nil, []) }
            guard last.date >= cutoff else { return (nil, points.map(\.value)) }
            return (last.value, points.dropLast().map(\.value))
        }

        let hr = split(hrDaily, latestNoOlderThan: startOfToday)
        let hrv = split(hrvDaily, latestNoOlderThan: startOfToday)
        let sleep = split(sleepNights, latestNoOlderThan: yesterday)

        let completeDays = energyDaily.filter { $0.date < startOfToday }
        let yesterdayEnergy = completeDays.last(where: { $0.date == yesterday })?.value
        let energyBaseline = completeDays.filter { $0.date != yesterday }.map(\.value)

        let computedReadiness = HealthScoreEngine.readiness(
            sleep: sleep.latest.flatMap { HealthScoreEngine.sleepScore(lastNightHours: $0, baseline: sleep.baseline) },
            restingHeartRate: hr.latest.flatMap { HealthScoreEngine.restingHeartRateScore(today: $0, baseline: hr.baseline) },
            hrv: hrv.latest.flatMap { HealthScoreEngine.hrvScore(today: $0, baseline: hrv.baseline) },
            activity: yesterdayEnergy.flatMap { HealthScoreEngine.activityBalanceScore(yesterday: $0, baseline: energyBaseline) }
        )
        readiness = computedReadiness

        let vo2Records = try store.records(type: VO2MaxEngine.vo2MaxType, from: d120, to: end)
        let trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)
        vo2Trend = trend

        let d28 = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: end))!
        let recentHistory = try store.workouts(from: d28, to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!)
        let loadAssessment = TrainingLoadMonitor.assess(history: recentHistory, plan: nil,
                                                         readiness: computedReadiness, today: end, calendar: calendar)
        let vo2MaxAlert = VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: loadAssessment.chronicWeeklyKm)

        dailyAdvice = DailyAdviceEngine.advise(readiness: computedReadiness, loadAlerts: loadAssessment.alerts,
                                               vo2MaxAlert: vo2MaxAlert, weightAlert: nil)
    }

    private func dailyAverages(type: String, from: Date, to: Date) throws -> [TrendPoint] {
        DailyAggregator.averages(
            resolver.resolve(try store.records(type: type, from: from, to: to)),
            calendar: calendar
        )
    }
}
```

- [ ] **Step 4: Wire the local store in CompanionApp**

In `Companion/CompanionApp.swift`, add one new stored property after `@StateObject private var viewModel: CompanionViewModel` (currently line 12):

```swift
    @StateObject private var advisorViewModel: CompanionAdvisorViewModel
```

Replace the `init()` body (currently lines 14-34) with:

```swift
    init() {
        let store = HKHealthStore() // UNE seule instance pour le reader et le background delivery
        healthStore = store
        let reader = HealthKitReaderLive(store: store)
        let tokenStore = KeychainTokenStore()
        let client = MacClient(endpointProvider: BonjourEndpointProvider(), tokenStore: tokenStore)
        let anchors = AnchorStore()
        let advisorStore: HealthStore
        let localImporter: LocalIngesting
        do {
            let localStore = try LocalStore()
            advisorStore = localStore.healthStore
            localImporter = localStore.importer
        } catch {
            os_log(.error, "LocalStore indisponible, mode relais seul: %{public}@", String(describing: error))
            advisorStore = HealthStore(unavailable: ())
            localImporter = NoOpImporter()
        }
        let engine = SyncEngine(reader: reader, pusher: client, anchors: anchors, localImporter: localImporter)
        self.reader = reader
        self.client = client
        self.engine = engine
        _viewModel = StateObject(wrappedValue: CompanionViewModel(
            engine: engine, pairer: client, tokenStore: tokenStore, anchors: anchors, planFetcher: client))
        _advisorViewModel = StateObject(wrappedValue: CompanionAdvisorViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
    }
```

(`body` is unchanged in this task — still `CompanionRootView(viewModel: viewModel)`. Task 3 updates that call site once `CompanionRootView` accepts `advisorViewModel`. `advisorViewModel` is a legal, if momentarily unread-elsewhere, stored property in between — this compiles.)

- [ ] **Step 5: Run `xcodegen generate`, then run the tests to verify they pass**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:CompanionTests/CompanionAdvisorViewModelTests`
Expected: PASS, all 5 tests.

- [ ] **Step 6: Run the full Companion suite to confirm no regression**

Run: `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, full suite, 0 failures — in particular `HKMapperTests.test_unknownQuantityType_isDropped` must still pass unchanged (Global Constraints).

- [ ] **Step 7: Commit**

```bash
git add Companion/CompanionAdvisorViewModel.swift Companion/CompanionApp.swift CompanionTests/CompanionAdvisorViewModelTests.swift
git commit -m "feat: add CompanionAdvisorViewModel computing readiness/advice/VO2max from the local store"
```

---

### Task 2: CompanionAdvisorView

**Files:**
- Create: `Companion/CompanionAdvisorView.swift`

**Interfaces:**
- Consumes: `CompanionAdvisorViewModel.readiness/.dailyAdvice/.vo2Trend/.hasLoaded/.storeUnavailable/.refresh()` (Task 1); `ReadinessScore.value/.label` (`HealthCheckShared/Analysis/HealthScoreEngine.swift`); `DailyAdvice.tier/.message`, `AdviceTier` (`.repos`/`.prudence`/`.opportunite`) (`HealthCheckShared/Analysis/DailyAdviceEngine.swift`); `VO2MaxTrend.recentAverage/.delta/.verdict`, `VO2MaxVerdict` (`.rising`/`.stable`/`.declining`) (`HealthCheckShared/Analysis/VO2MaxEngine.swift`).
- Produces: `CompanionAdvisorView(viewModel: CompanionAdvisorViewModel, lastSyncDate: Date?)` — consumed by Task 3 (`CompanionRootView`).

No new automated test: this codebase has no SwiftUI view-level test target, consistent with every other screen (`CompanionRootView`, `DashboardView`, `BodyView`). Verification for this task is: the full Companion suite still passes (no view-model regression) and the build succeeds.

- [ ] **Step 1: Create the view**

Create `Companion/CompanionAdvisorView.swift`:

```swift
import SwiftUI

/// Onglet « Conseils » : forme, conseil du jour, tendance VO2max — calculés
/// localement (`CompanionAdvisorViewModel`), jamais depuis le Mac. Pas de
/// poids sur cet écran (spec §2). Style visuel propre au Companion
/// (padding/rayon existants, cf. `CompanionRootView.syncCard`), pas le
/// gabarit du Mac (`WellnessViews.swift`) — ce fichier n'est pas dans les
/// sources de cette cible.
struct CompanionAdvisorView: View {
    @ObservedObject var viewModel: CompanionAdvisorViewModel
    let lastSyncDate: Date?

    var body: some View {
        ScrollView {
            Group {
                if viewModel.storeUnavailable {
                    storeUnavailableCard
                } else if viewModel.hasLoaded && viewModel.readiness == nil {
                    notEnoughDataCard
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let readiness = viewModel.readiness {
                            readinessCard(readiness)
                        }
                        if let advice = viewModel.dailyAdvice {
                            dailyAdviceCard(advice)
                        }
                        if let trend = viewModel.vo2Trend {
                            vo2Card(trend)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { viewModel.refresh() } }
        .onChange(of: lastSyncDate) { _, _ in viewModel.refresh() }
        .refreshable { viewModel.refresh() }
    }

    private func readinessCard(_ readiness: ReadinessScore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Forme", systemImage: "heart.fill")
                .font(.headline)
            Text("\(Int(readiness.value.rounded())) / 100")
                .font(.title2.bold())
                .monospacedDigit()
            Text(readiness.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func dailyAdviceCard(_ advice: DailyAdvice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(adviceTitle(advice.tier), systemImage: adviceSystemImage(advice.tier))
                .font(.headline)
                .foregroundStyle(adviceTint(advice.tier))
            Text(advice.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func adviceTint(_ tier: AdviceTier) -> Color {
        switch tier {
        case .repos: return .orange
        case .prudence: return .blue
        case .opportunite: return .green
        }
    }

    private func adviceSystemImage(_ tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "exclamationmark.triangle.fill"
        case .prudence: return "info.circle.fill"
        case .opportunite: return "checkmark.circle.fill"
        }
    }

    private func adviceTitle(_ tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "Repos conseillé"
        case .prudence: return "Prudence"
        case .opportunite: return "Opportunité"
        }
    }

    private func vo2Card(_ trend: VO2MaxTrend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("VO2max", systemImage: "lungs.fill")
                .font(.headline)
            Text(vo2VerdictLabel(trend.verdict))
                .font(.callout.weight(.semibold))
            Text("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg (\(trend.delta >= 0 ? "+" : "")\(trend.delta.formatted(.number.precision(.fractionLength(1)))) vs. les 90 jours précédents)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func vo2VerdictLabel(_ verdict: VO2MaxVerdict) -> String {
        switch verdict {
        case .rising: return "VO2max : en hausse"
        case .stable: return "VO2max : stable"
        case .declining: return "VO2max : en baisse"
        }
    }

    private var storeUnavailableCard: some View {
        VStack(spacing: 8) {
            Label("Base de données locale indisponible", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Redémarrez l'application. Si le problème persiste, vérifiez l'espace disque disponible sur l'iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var notEnoughDataCard: some View {
        VStack(spacing: 8) {
            Label("Pas encore assez de données", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text("Synchronisez, ou revenez dans quelques jours.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 2: Regenerate the project and run the full suite**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, full suite, 0 failures — this task adds no failing test of its own, so this confirms the build succeeds (a `View` file's compile errors would fail the whole target build before any test runs) and nothing upstream regressed.

- [ ] **Step 3: Commit**

```bash
git add Companion/CompanionAdvisorView.swift
git commit -m "feat: render the Conseils tab (readiness, daily advice, VO2max trend)"
```

---

### Task 3: Navigation — TabView + CompanionSyncView split

**Files:**
- Create: `Companion/CompanionSyncView.swift` (content moved from `CompanionRootView.swift`, no logic change)
- Modify: `Companion/CompanionRootView.swift` (becomes the `TabView` shell)
- Modify: `Companion/CompanionApp.swift:36-50` (the `body` property — pass `advisorViewModel` to `CompanionRootView`)

**Interfaces:**
- Consumes: `CompanionAdvisorView(viewModel:lastSyncDate:)` (Task 2); `CompanionAdvisorViewModel` (Task 1, already wired as `CompanionApp.advisorViewModel`); `CompanionViewModel.lastSyncDate` (`Companion/CompanionViewModel.swift:24`, already published).
- Produces: nothing consumed by a later task — this is the last task in the plan.

No new automated test: pure move (Companion/CompanionSyncView.swift) plus thin composition (CompanionRootView.swift) — verified by full suite pass and by the fact that a broken move would fail to compile.

- [ ] **Step 1: Create CompanionSyncView from the current CompanionRootView content**

Create `Companion/CompanionSyncView.swift` with the **exact current contents of `Companion/CompanionRootView.swift`**, with only the struct name changed (`CompanionRootView` → `CompanionSyncView`) and the file's doc-comment updated. Everything else — `@State` properties, `currentWeek`/`visibleWeeks` computed properties, `body`'s `NavigationStack`/`.confirmationDialog`, `pairedContent`, `pairingContent`, `syncCard`, `trainingPlanContent`, `emptyPlanCard`, `warningCard`, `goalSummary`, `weekCard`, `sessionList`, `sessionRow`, `monday(of:)` — moves verbatim, no logic change:

```swift
import SwiftUI

/// Onglet « Synchro » : appairage au Mac, statut de synchronisation, cache
/// local du plan d'entraînement. Anciennement l'écran unique de l'app
/// (`CompanionRootView`) — déplacé tel quel quand l'onglet « Conseils »
/// a été ajouté, aucune logique changée.
struct CompanionSyncView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @State private var code = ""
    @State private var showUnpairConfirmation = false

    private var currentWeek: TrainingWeekSummary? {
        guard let plan = viewModel.trainingPlan else { return nil }
        let currentMonday = monday(of: Date())
        return plan.weeks.first { Calendar.current.isDate($0.monday, inSameDayAs: currentMonday) }
            ?? plan.weeks.first { $0.monday >= currentMonday }
            ?? plan.weeks.last
    }

    private var visibleWeeks: [TrainingWeekSummary] {
        guard let plan = viewModel.trainingPlan else { return [] }
        let currentMonday = monday(of: Date())
        return plan.weeks
            .filter { $0.monday >= currentMonday }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isPaired {
                    pairedContent
                } else {
                    pairingContent
                }
            }
            .navigationTitle("HealthCheck")
            .confirmationDialog(
                "Oublier ce Mac ?",
                isPresented: $showUnpairConfirmation,
                titleVisibility: .visible
            ) {
                Button("Oublier", role: .destructive) {
                    viewModel.unpair()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("L'appairage sera supprimé et la synchronisation s'arrêtera. Vous devrez saisir un nouveau code depuis votre Mac pour la reprendre.")
            }
        }
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                syncCard

                if let error = viewModel.errorMessage {
                    warningCard(error)
                }

                trainingPlanContent

                Button("Oublier ce Mac", role: .destructive) {
                    showUnpairConfirmation = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.refreshTrainingPlan()
        }
    }

    private var pairingContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Appairage Mac", systemImage: "macbook.and.iphone")
                        .font(.title3.weight(.semibold))
                    Text("Sur votre Mac : HealthCheck > Données > carte iPhone > Appairer, puis saisissez le code ici.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Code à 6 chiffres", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await viewModel.submitPairingCode(code) }
                    } label: {
                        Label("Appairer", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(code.count != 6)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 8))

                if let error = viewModel.errorMessage {
                    warningCard(error)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Appairé", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                if viewModel.isSyncing {
                    ProgressView()
                }
            }

            if let last = viewModel.lastSyncDate {
                LabeledContent("Dernière synchro", value: last.formatted(.relative(presentation: .named)))
                    .font(.callout)
            }

            if let summary = viewModel.lastReportSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.syncNow() }
                } label: {
                    Label(viewModel.isSyncing ? "Synchronisation" : "Synchroniser", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isSyncing)
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await viewModel.refreshTrainingPlan() }
                } label: {
                    Label("Plan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingTrainingPlan)
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var trainingPlanContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plan d'entraînement")
                    .font(.title3.weight(.semibold))
                Spacer()
                if viewModel.isLoadingTrainingPlan {
                    ProgressView()
                }
            }

            if let plan = viewModel.trainingPlan {
                if let goal = plan.goal {
                    goalSummary(goal)
                }

                if let message = plan.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }

                if let week = currentWeek {
                    weekCard(week, title: "Cette semaine", expanded: true)
                }

                let otherWeeks = visibleWeeks.filter { week in
                    guard let currentWeek else { return true }
                    return !Calendar.current.isDate(week.monday, inSameDayAs: currentWeek.monday)
                }

                if !otherWeeks.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("Prochaines semaines")
                            .font(.headline)
                        ForEach(otherWeeks, id: \.monday) { week in
                            weekCard(week, title: nil, expanded: false)
                        }
                    }
                }
            } else {
                emptyPlanCard
            }
        }
    }

    private var emptyPlanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aucun plan local", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
            Text("Actualisez le plan quand le Mac est ouvert. Le dernier plan reçu restera ensuite disponible hors ligne.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await viewModel.refreshTrainingPlan() }
            } label: {
                Label("Actualiser le plan", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingTrainingPlan)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func goalSummary(_ goal: TrainingGoalSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(goal.name)
                .font(.headline)
            Text(goal.raceDate.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(goal.distanceKm.formatted(.number.precision(.fractionLength(1))) + " km", systemImage: "figure.run")
                Label("D+ \(Int(goal.elevationGainM.rounded())) m", systemImage: "mountain.2.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func weekCard(_ week: TrainingWeekSummary, title: String?, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? week.monday.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(week.role)
                    Text(week.targetKm.formatted(.number.precision(.fractionLength(1))) + " km")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if expanded {
                sessionList(week)
            } else {
                DisclosureGroup("\(week.sessions.count) séance(s)") {
                    sessionList(week)
                }
                .font(.callout)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sessionList(_ week: TrainingWeekSummary) -> some View {
        VStack(spacing: 0) {
            if week.sessions.isEmpty {
                Text("Aucune séance cible cette semaine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(week.sessions.enumerated()), id: \.offset) { index, session in
                    let id = viewModel.trainingSessionID(week: week, session: session, index: index)
                    sessionRow(session, id: id)
                    if index < week.sessions.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: TrainingSessionSummary, id: String) -> some View {
        let isCompleted = viewModel.isTrainingSessionCompleted(id: id)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                viewModel.toggleTrainingSessionCompleted(id: id)
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompleted ? .green : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Marquer comme non fait" : "Marquer comme fait")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.kind)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(session.targetText)
                        .font(.callout.monospacedDigit())
                }
                Text(session.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.rationale.isEmpty {
                    Text(session.rationale)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(isCompleted ? 0.58 : 1)
        }
        .padding(.vertical, 8)
    }

    private func monday(of date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        let offset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }
}
```

- [ ] **Step 2: Replace CompanionRootView.swift with the TabView shell**

Replace the entire contents of `Companion/CompanionRootView.swift` with:

```swift
import SwiftUI

/// Shell de navigation à deux onglets : « Conseils » (autonome, calcule
/// localement, indépendant de l'appairage) et « Synchro » (appairage,
/// statut, plan d'entraînement — contenu historique de l'app, inchangé,
/// déplacé dans CompanionSyncView).
struct CompanionRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var advisorViewModel: CompanionAdvisorViewModel

    var body: some View {
        TabView {
            NavigationStack {
                CompanionAdvisorView(viewModel: advisorViewModel, lastSyncDate: viewModel.lastSyncDate)
                    .navigationTitle("Conseils")
            }
            .tabItem { Label("Conseils", systemImage: "heart.text.square") }

            CompanionSyncView(viewModel: viewModel)
                .tabItem { Label("Synchro", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}
```

- [ ] **Step 3: Pass advisorViewModel from CompanionApp**

In `Companion/CompanionApp.swift`, in `body` (currently lines 36-50), change:

```swift
            CompanionRootView(viewModel: viewModel)
```

to:

```swift
            CompanionRootView(viewModel: viewModel, advisorViewModel: advisorViewModel)
```

(The rest of `body` — `.environment(\.locale, ...)`, the `.task` for HealthKit authorization and background sync registration — is unchanged.)

- [ ] **Step 4: Regenerate the project and run the full suite**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, full suite, 0 failures. This confirms: (a) the move introduced no compile errors, (b) `CompanionRootView`'s new signature compiles at its one call site in `CompanionApp`, (c) nothing in `CompanionViewModelTests` or `HKMapperTests` regressed.

- [ ] **Step 5: Commit**

```bash
git add Companion/CompanionSyncView.swift Companion/CompanionRootView.swift Companion/CompanionApp.swift
git commit -m "feat: split CompanionRootView into a 2-tab shell (Conseils, Synchro)"
```

---

## After the plan

Three commits land the Companion advisor screen: a local-only `CompanionAdvisorViewModel` (Task 1), the `CompanionAdvisorView` that renders it (Task 2), and the navigation restructuring that surfaces it as a first-class tab independent of pairing state (Task 3). No file under `HealthCheck/` or `HealthCheckShared/` changes — this plan is entirely additive to the `HealthCheckCompanion` target and its tests. `HKMapperTests.test_unknownQuantityType_isDropped` (the "balance = territoire Withings" rule) is never touched.

Manual verification recommended once the plan is done, consistent with every prior Companion sub-project (per `TODOS.md`, HealthKit authorization/background-delivery behavior can't be verified from a simulator): install on a physical iPhone, confirm the Conseils tab appears before pairing to a Mac, confirm it populates after HealthKit permission is granted and some history exists, and confirm pull-to-refresh and post-sync refresh both work.
