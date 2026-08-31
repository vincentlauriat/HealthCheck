# Weight Advisor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn weight from a passive display into an advisory signal — a rate/direction trend, an optional personal goal (target weight + date) with trajectory evaluation, and a safety alert when the rate exceeds a usual medical guideline — surfaced on the Corps screen and folded into the Accueil "Conseil du jour" card.

**Architecture:** A new pure engine `HealthCheckShared/Analysis/WeightEngine.swift` (14-day recent vs. 14-day prior window comparison, same lesson as `VO2MaxEngine`: windowed averages, never first/last point) feeds a new `WeightGoal` model (CRUD, mirrors `RaceGoal`), extends `DailyAdviceEngine.advise(...)` with a third alert source, and gets wired into `DashboardViewModel` (Accueil) and `BodyViewModel`/`BodyView` (Corps, plus goal creation/deletion UI). macOS-only for wiring and UI — the engine lives in the shared module but nothing wires it into the Companion app in this plan.

**Tech Stack:** Swift, XCTest, XcodeGen-generated Xcode project, GRDB-backed `HealthStore`.

**Spec:** `docs/superpowers/specs/2026-08-31-weight-advisor-design.md`

## Global Constraints

- Every engine follows the existing `Analysis/` convention: `enum` of `static func`s, no clock/calendar reads inside the engine, `today`/`calendar` always explicit parameters.
- Any test written specifically to catch a bug must be seen to fail against that exact bug before being accepted (repo convention, `CLAUDE.md`) — for new logic, the red step of TDD (compile failure, then the correct assertion failure) satisfies this.
- macOS test command: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- Run `xcodegen generate` after adding a new source file, before the first build that references it.
- Never `git add` the generated `HealthCheck.xcodeproj` — gitignored.
- Never touch `Companion/` or `CompanionTests/`.
- `WeightEngine` constants (spec §5): `recentWindowDays = 14`, `priorWindowDays = 14`, `stableNoiseThresholdKg = 0.15`, `onTrackToleranceRatio = 0.20`, `safeWarningRatePercent = 1.0`, `safeInfoRatePercent = 0.5`.
- **Floating-point boundary tests use margin, not the literal threshold.** `0.15`, `0.20`, `1.0`, `0.5` are decimal fractions that are not exactly representable in `Double` — a test asserting behavior at the *exact* literal boundary risks failing on an implementation-irrelevant rounding artifact. Every boundary test in this plan uses a value clearly on one side of the threshold (margin ≥ 0.01 in the compared unit) rather than the literal constant itself. This still catches a mutation to the threshold's *value* (e.g. `0.20` → `0.25`) — it just doesn't gamble on bit-exact equality at the edge pixel.
- **`DailyAdviceEngine.advise(...)` gains a 4th parameter is a compile-atomic change** (like `SessionKind`/`InsightInputs` at the VO2max sub-project): Task 3 updates the engine, every existing call in `DailyAdviceEngineTests.swift`, and the one call in `DashboardViewModel.swift` in the same commit — the module will not compile in between.
- **Spec correction (found while reading the real code for this plan):** spec §3's architecture diagram lists `weightGoal = WeightGoal.active(...)` as part of `DashboardViewModel`'s pipeline, but nothing `DashboardViewModel` computes actually consumes a goal — `WeightEngine.safetyAlert(trend:trainingLoadElevated:)` takes no goal, and `weightTrajectory` is explicitly Corps-only per spec §8. Task 3 does **not** load `WeightGoal` in `DashboardViewModel` — doing so would be a dead `store.weightGoals()` call on every Accueil refresh. Only `BodyViewModel` (Task 4) loads it.
- **Spec correction (ordering):** spec §8 says `DashboardViewModel` "reuses `weightDaily` (already loaded)" — in the real code, `weightDaily` is computed at the very end of `loadWellness()`, *after* the block that currently computes `dailyAdvice`. Task 3 moves the `weightDaily` computation earlier in the method (right after `inputs.vo2Trend`) so it exists before `weightTrend`/`dailyAdvice` need it. The existing `inputs.weightDelta30d` line moves with it, unchanged.
- **`d30`'s wall-clock anchoring is a pre-existing, out-of-scope issue.** `DashboardViewModel.loadWellness()`'s `d30 = calendar.date(byAdding: .day, value: -30, to: end)` (`end = now()`, not `startOfDay`) has the same class of day-boundary imprecision the final review of the daily-advice sub-project fixed for `d28` — but `d30` feeds `hrDaily`/`hrvDaily`/`energyDaily`/`sleepNights` too, not just weight. Fixing it would touch every baseline calculation in this method, well beyond this plan's scope. Not fixed here.

---

### Task 1: WeightGoal model + HealthStore storage

**Files:**
- Create: `HealthCheckShared/Models/WeightGoal.swift`
- Modify: `HealthCheckShared/Store/HealthStore.swift:66-76` (new `weight_goal` table, inserted right after the existing `race_goal` table block, still inside the `init` write transaction) and after line 319 (three new methods, after `raceGoals()`, before the file's closing brace)
- Test: `HealthCheckTests/WeightGoalStoreTests.swift`

**Interfaces:**
- Produces: `struct WeightGoal: Equatable { let id: String; let targetWeightKg: Double; let targetDate: Date; let createdAt: Date }`; `WeightGoal.active(in: [WeightGoal], today: Date, calendar: Calendar = .current) -> WeightGoal?`; `HealthStore.saveWeightGoal(_ goal: WeightGoal) throws`; `HealthStore.deleteWeightGoal(id: String) throws`; `HealthStore.weightGoals() throws -> [WeightGoal]`.

- [ ] **Step 1: Write the failing tests**

Create `HealthCheckTests/WeightGoalStoreTests.swift`:

```swift
import XCTest
@testable import HealthCheck

final class WeightGoalStoreTests: XCTestCase {
    private func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Europe/Paris")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!
    }

    private func goal(_ targetKg: Double, _ day: String) -> WeightGoal {
        WeightGoal(id: UUID().uuidString, targetWeightKg: targetKg, targetDate: date(day),
                  createdAt: date("2026-08-01"))
    }

    func test_saveWeightGoal_roundTripsThroughStore() throws {
        let store = try HealthStore(path: ":memory:")
        let g = goal(70.0, "2026-12-25")
        try store.saveWeightGoal(g)
        XCTAssertEqual(try store.weightGoals(), [g])
    }

    func test_saveWeightGoal_sameIdTwice_updatesInsteadOfDuplicating() throws {
        let store = try HealthStore(path: ":memory:")
        let first = goal(70.0, "2026-12-25")
        try store.saveWeightGoal(first)
        let updated = WeightGoal(id: first.id, targetWeightKg: 68.0,
                                 targetDate: first.targetDate, createdAt: first.createdAt)
        try store.saveWeightGoal(updated)
        XCTAssertEqual(try store.weightGoals(), [updated])
    }

    func test_deleteWeightGoal_removesOnlyThatGoal() throws {
        let store = try HealthStore(path: ":memory:")
        let a = goal(70.0, "2026-09-27"), b = goal(65.0, "2026-10-11")
        try store.saveWeightGoal(a)
        try store.saveWeightGoal(b)
        try store.deleteWeightGoal(id: a.id)
        XCTAssertEqual(try store.weightGoals().map(\.targetWeightKg), [65.0])
    }

    func test_weightGoals_areSortedByTargetDate() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveWeightGoal(goal(65.0, "2026-10-11"))
        try store.saveWeightGoal(goal(70.0, "2026-09-27"))
        XCTAssertEqual(try store.weightGoals().map(\.targetWeightKg), [70.0, 65.0])
    }

    func test_active_picksNearestFutureTargetDate_andIgnoresPastOnes() {
        let past = goal(72.0, "2026-08-01")
        let soon = goal(70.0, "2026-09-27")
        let later = goal(65.0, "2026-10-11")
        XCTAssertEqual(WeightGoal.active(in: [past, later, soon], today: date("2026-08-23"))?.targetWeightKg, 70.0)
    }

    func test_active_targetDateItself_isStillActive() {
        let today = goal(70.0, "2026-08-23")
        XCTAssertEqual(WeightGoal.active(in: [today], today: date("2026-08-23"))?.targetWeightKg, 70.0)
    }

    func test_active_allTargetsPast_isNil() {
        XCTAssertNil(WeightGoal.active(in: [goal(70.0, "2026-08-01")], today: date("2026-08-23")))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/WeightGoalStoreTests`
Expected: FAIL to compile — `WeightGoal` and the `HealthStore` weight-goal methods don't exist yet.

- [ ] **Step 3: Create the model**

Create `HealthCheckShared/Models/WeightGoal.swift`:

```swift
import Foundation

/// Objectif de poids : parallèle à RaceGoal, même sémantique de mise à jour
/// — l'id est un UUID créé à la saisie, le réenregistrer avec le même id
/// met à jour plutôt que dupliquer.
struct WeightGoal: Equatable {
    let id: String
    let targetWeightKg: Double
    let targetDate: Date
    let createdAt: Date

    /// Objectif actif : la date cible future la plus proche. Le jour cible
    /// compte encore comme futur (comparaison au début du jour) — même
    /// sémantique que RaceGoal.active.
    static func active(in goals: [WeightGoal], today: Date,
                       calendar: Calendar = .current) -> WeightGoal? {
        let startOfToday = calendar.startOfDay(for: today)
        return goals
            .filter { calendar.startOfDay(for: $0.targetDate) >= startOfToday }
            .min { $0.targetDate < $1.targetDate }
    }
}
```

- [ ] **Step 4: Add the table and the storage methods**

In `HealthCheckShared/Store/HealthStore.swift`, insert a new table creation right after the `race_goal` table block (currently lines 66-75, ending with the `"""` that closes that SQL string, right before line 76's `}`):

```swift
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS weight_goal (
                    id TEXT PRIMARY KEY,
                    targetWeightKg REAL NOT NULL,
                    targetDate TEXT NOT NULL,
                    createdAt TEXT NOT NULL
                )
                """)
```

Then, after `raceGoals()` (currently ending at line 319, right before the file's closing `}` at line 320), add:

```swift

    func saveWeightGoal(_ goal: WeightGoal) throws {
        try queue().write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO weight_goal
                    (id, targetWeightKg, targetDate, createdAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [goal.id, goal.targetWeightKg,
                            Self.isoFormatter.string(from: goal.targetDate),
                            Self.isoFormatter.string(from: goal.createdAt)])
        }
    }

    func deleteWeightGoal(id: String) throws {
        try queue().write { db in
            try db.execute(sql: "DELETE FROM weight_goal WHERE id = ?", arguments: [id])
        }
    }

    func weightGoals() throws -> [WeightGoal] {
        try queue().read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM weight_goal ORDER BY targetDate")
            return rows.compactMap { row in
                guard let targetDate = Self.isoFormatter.date(from: row["targetDate"]),
                      let createdAt = Self.isoFormatter.date(from: row["createdAt"])
                else { return nil }
                return WeightGoal(id: row["id"], targetWeightKg: row["targetWeightKg"],
                                  targetDate: targetDate, createdAt: createdAt)
            }
        }
    }
```

- [ ] **Step 5: Run `xcodegen generate`, then run the tests to verify they pass**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/WeightGoalStoreTests`
Expected: PASS, all 7 tests.

- [ ] **Step 6: Commit**

```bash
git add HealthCheckShared/Models/WeightGoal.swift HealthCheckShared/Store/HealthStore.swift HealthCheckTests/WeightGoalStoreTests.swift
git commit -m "feat: add WeightGoal model and storage"
```

---

### Task 2: WeightEngine (pure engine) + METHODOLOGY.md

**Files:**
- Create: `HealthCheckShared/Analysis/WeightEngine.swift`
- Test: `HealthCheckTests/WeightEngineTests.swift`
- Modify: `docs/METHODOLOGY.md` (new `## 16` section, inserted before the current `## 15. Avertissement` at line 1010, which becomes `## 16`)

**Interfaces:**
- Consumes: `WeightGoal` (Task 1); `TrendPoint { let date: Date; let value: Double }` (`HealthCheckShared/Models/TrendPoint.swift`, already exists); `LoadAlert { let severity: Severity; let message: String }` with `Severity { case info, warning }` (`HealthCheckShared/Analysis/TrainingLoadMonitor.swift`, already exists).
- Produces: `enum WeightDirection: Equatable { case losing, gaining, stable }`; `struct WeightTrend: Equatable { let recentAverageKg: Double; let priorAverageKg: Double; let weeklyRateKg: Double; let direction: WeightDirection }`; `enum TrajectoryVerdict: Equatable { case onTrack, tooSlow, tooFast }`; `struct WeightTrajectory: Equatable { let verdict: TrajectoryVerdict; let requiredWeeklyRateKg: Double; let weeksRemaining: Double }`; `WeightEngine.trend(weights: [TrendPoint], today: Date, calendar: Calendar) -> WeightTrend?`; `WeightEngine.trajectory(trend: WeightTrend?, goal: WeightGoal?, today: Date, calendar: Calendar) -> WeightTrajectory?`; `WeightEngine.safetyAlert(trend: WeightTrend?, trainingLoadElevated: Bool) -> LoadAlert?`.

- [ ] **Step 1: Write the failing tests**

Create `HealthCheckTests/WeightEngineTests.swift`:

```swift
import XCTest
@testable import HealthCheck

final class WeightEngineTests: XCTestCase {
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

    func weight(_ day: String, _ kg: Double) -> TrendPoint {
        TrendPoint(date: date(day), value: kg)
    }

    // MARK: - trend
    // today = 2026-08-23. Recent window = 2026-08-10..2026-08-23 (14 days).
    // Prior window = 2026-07-27..2026-08-09 (the 14 days before that).

    func test_trend_nilWhenRecentWindowHasNoSample() {
        let weights = [weight("2026-07-30", 70.0)] // only in the prior window
        XCTAssertNil(WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trend_nilWhenPriorWindowHasNoSample() {
        let weights = [weight("2026-08-15", 70.0)] // only in the recent window
        XCTAssertNil(WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trend_stableWhenDeltaClearlyWithinNoiseThreshold() {
        // delta = 0.05, clearly under stableNoiseThresholdKg (0.15)
        let weights = [weight("2026-08-15", 70.05), weight("2026-07-30", 70.0)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.direction, .stable)
    }

    func test_trend_losingWhenDeltaClearlyBeyondNoiseThreshold() {
        // delta = -0.4, clearly beyond stableNoiseThresholdKg (0.15)
        let weights = [weight("2026-08-15", 69.6), weight("2026-07-30", 70.0)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.direction, .losing)
    }

    func test_trend_gainingWhenDeltaClearlyBeyondNoiseThreshold() {
        let weights = [weight("2026-08-15", 70.4), weight("2026-07-30", 70.0)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.direction, .gaining)
    }

    func test_trend_weeklyRateIsHalfTheAverageDeltaBetweenTheTwoWindows() {
        // delta = -1.4 over the 2-week gap between window centers -> -0.7/week
        let weights = [weight("2026-08-15", 70.0), weight("2026-07-30", 71.4)]
        let trend = WeightEngine.trend(weights: weights, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.weeklyRateKg ?? .nan, -0.7, accuracy: 0.001)
    }

    // MARK: - trajectory

    private func trend(recentAvg: Double, weeklyRate: Double) -> WeightTrend {
        WeightTrend(recentAverageKg: recentAvg, priorAverageKg: recentAvg - weeklyRate * 2,
                   weeklyRateKg: weeklyRate,
                   direction: weeklyRate > 0 ? .gaining : (weeklyRate < 0 ? .losing : .stable))
    }

    private func goal(_ targetKg: Double, daysFromToday: Int) -> WeightGoal {
        let today = date("2026-08-23")
        let target = calendar.date(byAdding: .day, value: daysFromToday, to: today)!
        return WeightGoal(id: "g", targetWeightKg: targetKg, targetDate: target, createdAt: today)
    }

    func test_trajectory_nilWithoutGoal() {
        XCTAssertNil(WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2),
                                             goal: nil, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trajectory_nilWhenTargetDateHasPassed() {
        let g = goal(71, daysFromToday: -1)
        XCTAssertNil(WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2),
                                             goal: g, today: date("2026-08-23"), calendar: calendar))
    }

    func test_trajectory_onTrackAtExactRequiredRate() {
        // target 71 from 75, 14 days (2 weeks) remaining -> required -2.0 kg/week
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2.0),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
        XCTAssertEqual(result?.requiredWeeklyRateKg ?? .nan, -2.0, accuracy: 0.001)
        XCTAssertEqual(result?.weeksRemaining ?? .nan, 2.0, accuracy: 0.001)
    }

    func test_trajectory_onTrackNearUpperTolerance() {
        // ratio = 1.19, clearly under the 1.20 tolerance ceiling
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2.38),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
    }

    func test_trajectory_tooFastClearlyPastUpperTolerance() {
        // ratio = 1.21, clearly over the 1.20 tolerance ceiling
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -2.42),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .tooFast)
    }

    func test_trajectory_onTrackNearLowerTolerance() {
        // ratio = 0.81, clearly over the 0.80 tolerance floor
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -1.62),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
    }

    func test_trajectory_tooSlowClearlyPastLowerTolerance() {
        // ratio = 0.79, clearly under the 0.80 tolerance floor
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: -1.58),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .tooSlow)
    }

    func test_trajectory_tooSlowWhenActuallyMovingTheWrongWay() {
        // required is -2.0 (need to lose), actual is +1.0 (gaining) -> ratio negative
        let g = goal(71, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: 1.0),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .tooSlow)
    }

    func test_trajectory_onTrackWhenAlreadyAtTarget() {
        // targetWeightKg == recentAverageKg -> requiredWeeklyRateKg ~ 0
        let g = goal(75, daysFromToday: 14)
        let result = WeightEngine.trajectory(trend: trend(recentAvg: 75, weeklyRate: 0.1),
                                             goal: g, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(result?.verdict, .onTrack)
        XCTAssertEqual(result?.requiredWeeklyRateKg ?? .nan, 0, accuracy: 0.001)
    }

    // MARK: - safetyAlert
    // recentAverageKg = 100 throughout, so weeklyRateKg numerically equals
    // the rate as a percentage of body weight — no separate percent math to
    // get wrong in the fixtures.

    func test_safetyAlert_nilWhenTrendIsNil() {
        XCTAssertNil(WeightEngine.safetyAlert(trend: nil, trainingLoadElevated: false))
    }

    func test_safetyAlert_nilClearlyBelowInfoThreshold() {
        // 0.3 %/week, clearly under safeInfoRatePercent (0.5)
        let t = trend(recentAvg: 100, weeklyRate: 0.3)
        XCTAssertNil(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false))
    }

    func test_safetyAlert_infoClearlyAboveInfoThreshold() {
        // 0.6 %/week, clearly over 0.5, clearly under safeWarningRatePercent (1.0)
        let t = trend(recentAvg: 100, weeklyRate: 0.6)
        XCTAssertEqual(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)?.severity, .info)
    }

    func test_safetyAlert_infoJustBelowWarningThreshold() {
        // 0.9 %/week, clearly under safeWarningRatePercent (1.0)
        let t = trend(recentAvg: 100, weeklyRate: 0.9)
        XCTAssertEqual(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)?.severity, .info)
    }

    func test_safetyAlert_warningClearlyAboveWarningThreshold() {
        // 1.1 %/week, clearly over safeWarningRatePercent (1.0)
        let t = trend(recentAvg: 100, weeklyRate: 1.1)
        XCTAssertEqual(WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)?.severity, .warning)
    }

    func test_safetyAlert_messageHardenedWhenTrainingLoadElevated() {
        let t = trend(recentAvg: 100, weeklyRate: 2.0)
        let alert = WeightEngine.safetyAlert(trend: t, trainingLoadElevated: true)
        XCTAssertEqual(alert?.severity, .warning)
        XCTAssertTrue(alert?.message.contains("charge d'entraînement") ?? false,
                      "le message durci doit mentionner la charge d'entraînement")
    }

    func test_safetyAlert_messageNotHardenedWhenTrainingLoadNotElevated() {
        let t = trend(recentAvg: 100, weeklyRate: 2.0)
        let alert = WeightEngine.safetyAlert(trend: t, trainingLoadElevated: false)
        XCTAssertEqual(alert?.severity, .warning)
        XCTAssertFalse(alert?.message.contains("charge d'entraînement") ?? true,
                       "sans charge élevée, le message ne doit pas mentionner l'entraînement")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/WeightEngineTests`
Expected: FAIL to compile — `WeightEngine`, `WeightTrend`, `WeightTrajectory` do not exist yet.

- [ ] **Step 3: Write the implementation**

Create `HealthCheckShared/Analysis/WeightEngine.swift`:

```swift
import Foundation

enum WeightDirection: Equatable {
    case losing
    case gaining
    case stable
}

struct WeightTrend: Equatable {
    let recentAverageKg: Double
    let priorAverageKg: Double
    let weeklyRateKg: Double
    let direction: WeightDirection
}

enum TrajectoryVerdict: Equatable {
    case onTrack
    case tooSlow
    case tooFast
}

struct WeightTrajectory: Equatable {
    let verdict: TrajectoryVerdict
    let requiredWeeklyRateKg: Double
    let weeksRemaining: Double
}

/// Interprète le poids comme un signal d'entraînement/santé plutôt qu'une
/// simple courbe : tendance sur deux fenêtres glissantes (14 jours récents
/// contre 14 jours juste avant — même principe que VO2MaxEngine : des
/// moyennes de fenêtre, jamais un delta premier/dernier point, fragile aux
/// valeurs isolées), trajectoire vers un objectif optionnel, et alerte de
/// sécurité de rythme. Pur et sans horloge propre, comme tous les autres
/// moteurs.
enum WeightEngine {
    static let recentWindowDays = 14
    static let priorWindowDays = 14
    static let stableNoiseThresholdKg = 0.15
    static let onTrackToleranceRatio = 0.20
    static let safeWarningRatePercent = 1.0
    static let safeInfoRatePercent = 0.5

    static func trend(weights: [TrendPoint], today: Date, calendar: Calendar) -> WeightTrend? {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        let recentStart = calendar.date(byAdding: .day, value: -recentWindowDays, to: endExclusive)!
        let priorStart = calendar.date(byAdding: .day, value: -(recentWindowDays + priorWindowDays),
                                       to: endExclusive)!

        let recentValues = weights
            .filter { $0.date >= recentStart && $0.date < endExclusive }
            .map(\.value)
        let priorValues = weights
            .filter { $0.date >= priorStart && $0.date < recentStart }
            .map(\.value)
        guard !recentValues.isEmpty, !priorValues.isEmpty else { return nil }

        let recentAverage = recentValues.reduce(0, +) / Double(recentValues.count)
        let priorAverage = priorValues.reduce(0, +) / Double(priorValues.count)
        let delta = recentAverage - priorAverage
        let weeklyRate = delta / 2.0 // 2 semaines entre les centres des deux fenêtres
        let direction: WeightDirection = abs(delta) < stableNoiseThresholdKg
            ? .stable : (delta > 0 ? .gaining : .losing)

        return WeightTrend(recentAverageKg: recentAverage, priorAverageKg: priorAverage,
                           weeklyRateKg: weeklyRate, direction: direction)
    }

    static func trajectory(trend: WeightTrend?, goal: WeightGoal?, today: Date,
                           calendar: Calendar) -> WeightTrajectory? {
        guard let trend, let goal else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                           to: calendar.startOfDay(for: goal.targetDate)).day ?? 0
        guard days > 0 else { return nil }
        let weeksRemaining = Double(days) / 7.0
        let requiredWeeklyRate = (goal.targetWeightKg - trend.recentAverageKg) / weeksRemaining

        guard abs(requiredWeeklyRate) > 0.01 else {
            return WeightTrajectory(verdict: .onTrack, requiredWeeklyRateKg: requiredWeeklyRate,
                                    weeksRemaining: weeksRemaining)
        }
        // ratio < 0 (rythme réel de signe opposé au rythme requis) tombe
        // naturellement sous le plancher de tolérance -> .tooSlow, pas un
        // cas séparé : ne pas progresser vers l'objectif reste ne pas
        // progresser assez vite, que ce soit à l'arrêt ou à contresens.
        let ratio = trend.weeklyRateKg / requiredWeeklyRate
        let verdict: TrajectoryVerdict
        if ratio < 1 - onTrackToleranceRatio {
            verdict = .tooSlow
        } else if ratio > 1 + onTrackToleranceRatio {
            verdict = .tooFast
        } else {
            verdict = .onTrack
        }
        return WeightTrajectory(verdict: verdict, requiredWeeklyRateKg: requiredWeeklyRate,
                                weeksRemaining: weeksRemaining)
    }

    static func safetyAlert(trend: WeightTrend?, trainingLoadElevated: Bool) -> LoadAlert? {
        guard let trend, trend.recentAverageKg > 0 else { return nil }
        let ratePercent = abs(trend.weeklyRateKg) / trend.recentAverageKg * 100
        if ratePercent >= safeWarningRatePercent {
            let base = "Rythme de variation du poids au-dessus du repère usuel (≈1 %/semaine)."
            let message = trainingLoadElevated
                ? base + " Combiné à une charge d'entraînement élevée, veillez à un apport énergétique suffisant."
                : base
            return LoadAlert(severity: .warning, message: message)
        }
        if ratePercent >= safeInfoRatePercent {
            return LoadAlert(severity: .info, message: "Rythme de variation du poids notable — à surveiller.")
        }
        return nil
    }
}
```

- [ ] **Step 4: Run `xcodegen generate`, then run the tests to verify they pass**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/WeightEngineTests`
Expected: PASS, all 22 tests.

- [ ] **Step 5: Document the engine in METHODOLOGY.md**

In `docs/METHODOLOGY.md`, insert a new section immediately before the current `## 15. Avertissement` (line 1010), and renumber that heading to `## 16. Avertissement`:

```markdown
## 15. Suivi de poids — `WeightEngine`

**Question :** « est-ce que je perds/prends du poids, à quel rythme, et est-ce
que ce rythme est sûr et cohérent avec mon objectif ? »

**Entrées.** La série journalière de poids (`[TrendPoint]`), un objectif de
poids optionnel (`WeightGoal` : poids cible + date cible), et un booléen
indiquant si la charge d'entraînement du jour est déjà signalée comme
élevée ailleurs (`TrainingLoadMonitor.assess(...).alerts` contient un
`.warning` — jamais un second calcul de charge).

**Tendance.** Comme `VO2MaxEngine` (§11.8), une comparaison de deux fenêtres
glissantes plutôt qu'un delta premier/dernier point (fragile aux valeurs
isolées) :

```swift
recentWindowDays = 14   // fenêtre récente, jusqu'à aujourd'hui inclus
priorWindowDays = 14    // fenêtre antérieure, immédiatement avant
stableNoiseThresholdKg = 0.15
```

`trend(weights:today:calendar:)` retourne `nil` si l'une des deux fenêtres
n'a aucune pesée. Le rythme hebdomadaire est le delta entre les deux
moyennes divisé par 2 (les deux semaines qui séparent les centres des
fenêtres) ; la direction est `.stable` sous le seuil de bruit, `.gaining`/
`.losing` sinon.

**Trajectoire.** `nil` sans objectif actif, ou si la date cible est déjà
dépassée. Avec un objectif, le rythme requis est
`(poidsCible − moyenneRécente) / semainesRestantes`, comparé au rythme réel :

| Condition | Constante | Verdict |
|---|---|---|
| rythme réel dans ±20 % du rythme requis | `onTrackToleranceRatio = 0.20` | `.onTrack` |
| en dessous (y compris rythme de signe opposé) | | `.tooSlow` |
| au-dessus | | `.tooFast` |

**Alerte de sécurité.** Repère médical usuel, pas une constante validée
spécifiquement pour cette application (réserve du §16) :

```swift
safeInfoRatePercent = 0.5      // % du poids corporel / semaine
safeWarningRatePercent = 1.0
```

En dessous de 0,5 %/semaine, aucune alerte. Entre 0,5 % et 1 %, `.info`. Au
delà de 1 %, `.warning` — le message est durci (mention explicite de la
charge d'entraînement) quand `trainingLoadElevated` est vrai, sans jamais
recalculer cette charge : c'est une alerte déjà produite par
`TrainingLoadMonitor` qui est simplement transmise.

**Ce que ça ne fait pas.** Le moteur ne lit ni le store ni l'horloge, ne
recalcule jamais la charge d'entraînement, et n'ajuste le repère de rythme
sûr à la morphologie ou à l'état de santé de l'utilisateur — un même
pourcentage s'applique à tous.

---
```

- [ ] **Step 6: Commit**

```bash
git add HealthCheckShared/Analysis/WeightEngine.swift HealthCheckTests/WeightEngineTests.swift docs/METHODOLOGY.md
git commit -m "feat: add WeightEngine trend/trajectory/safety-alert logic"
```

---

### Task 3: DailyAdviceEngine weightAlert parameter + DashboardViewModel wiring

**Files:**
- Modify: `HealthCheckShared/Analysis/DailyAdviceEngine.swift` (whole file — signature + scan order)
- Modify: `HealthCheckTests/DailyAdviceEngineTests.swift` (whole file — every existing call gains `weightAlert: nil`, plus 2 new tests)
- Modify: `HealthCheck/ViewModels/DashboardViewModel.swift:111-136` (reorder `weightDaily`, add weight computations, extend the `advise(...)` call)
- Test: `HealthCheckTests/DashboardViewModelTests.swift` (1 new test)

**Interfaces:**
- Consumes: `WeightEngine.trend(weights:today:calendar:)`, `WeightEngine.safetyAlert(trend:trainingLoadElevated:)` (Task 2).
- Produces: `DailyAdviceEngine.advise(readiness:loadAlerts:vo2MaxAlert:weightAlert:) -> DailyAdvice?` (extended signature) — consumed by Task 4 only insofar as `BodyViewModel` also calls `WeightEngine.safetyAlert` directly (not through `DailyAdviceEngine`).

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `HealthCheckTests/DailyAdviceEngineTests.swift` with:

```swift
import XCTest
@testable import HealthCheck

final class DailyAdviceEngineTests: XCTestCase {
    private func readiness(label: String) -> ReadinessScore {
        ReadinessScore(value: 0, label: label, components: [])
    }

    private func alert(_ severity: LoadAlert.Severity, _ message: String) -> LoadAlert {
        LoadAlert(severity: severity, message: message)
    }

    func test_advise_reposTierAndGenericMessageWhenNoWarningPresent() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Récupération conseillée"),
            loadAlerts: [],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .repos)
        XCTAssertEqual(advice?.message, "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_advise_prudenceTierAndGenericMessageWhenOnlyInfoAlertsPresent() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "Vous pouvez en faire un peu plus.")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .prudence)
        XCTAssertEqual(advice?.message, "Restez sur des séances modérées aujourd'hui — ce n'est pas le jour pour repousser vos limites.")
    }

    func test_advise_opportuniteTierWhenLabelIsBonneForme() {
        let advice = DailyAdviceEngine.advise(readiness: readiness(label: "Bonne forme"),
                                              loadAlerts: [], vo2MaxAlert: nil, weightAlert: nil)
        XCTAssertEqual(advice?.tier, .opportunite)
        XCTAssertEqual(advice?.message, "Vous êtes en forme — bon moment pour une séance clé.")
    }

    func test_advise_opportuniteTierWhenLabelIsExcellenteForme() {
        let advice = DailyAdviceEngine.advise(readiness: readiness(label: "Excellente forme"),
                                              loadAlerts: [], vo2MaxAlert: nil, weightAlert: nil)
        XCTAssertEqual(advice?.tier, .opportunite)
    }

    func test_advise_warningIgnoredUnderOpportuniteTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Excellente forme"),
            loadAlerts: [alert(.warning, "Vous progressez trop vite — réduisez cette semaine.")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .opportunite)
        XCTAssertEqual(advice?.message, "Vous êtes en forme — bon moment pour une séance clé.",
                      "une alerte .warning ne doit jamais remonter sous le palier opportunité")
    }

    func test_advise_warningSubstitutedUnderReposTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Récupération conseillée"),
            loadAlerts: [alert(.warning, "Vous progressez trop vite — réduisez cette semaine.")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.message, "Vous progressez trop vite — réduisez cette semaine.")
    }

    func test_advise_determinismLoadAlertsWinOverVo2MaxAlertWhenBothWarn() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.warning, "alerte de charge")],
            vo2MaxAlert: alert(.warning, "alerte VO2max"),
            weightAlert: nil
        )
        XCTAssertEqual(advice?.message, "alerte de charge")
    }

    func test_advise_vo2MaxAlertUsedWhenLoadAlertsHaveNoWarning() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "alerte de charge info")],
            vo2MaxAlert: alert(.warning, "alerte VO2max"),
            weightAlert: nil
        )
        XCTAssertEqual(advice?.message, "alerte VO2max")
    }

    func test_advise_nilReadinessReturnsNil() {
        XCTAssertNil(DailyAdviceEngine.advise(readiness: nil, loadAlerts: [], vo2MaxAlert: nil, weightAlert: nil))
    }

    // Un libellé inconnu (renommage futur de HealthScoreEngine.label(for:),
    // par exemple) ne doit jamais retomber silencieusement sur le palier le
    // plus optimiste — ça masquerait une vraie alerte .warning.
    func test_advise_unknownLabelFailsSafeToPrudenceTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Libellé inconnu"),
            loadAlerts: [alert(.warning, "alerte de charge")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .prudence)
        XCTAssertEqual(advice?.message, "alerte de charge",
                      "palier .prudence : la substitution d'alerte doit rester active")
    }

    func test_advise_weightAlertUsedWhenLoadAndVo2MaxHaveNoWarning() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "alerte de charge info")],
            vo2MaxAlert: nil,
            weightAlert: alert(.warning, "alerte de poids")
        )
        XCTAssertEqual(advice?.message, "alerte de poids")
    }

    func test_advise_determinismVo2MaxAlertWinsOverWeightAlertWhenBothWarn() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [],
            vo2MaxAlert: alert(.warning, "alerte VO2max"),
            weightAlert: alert(.warning, "alerte de poids")
        )
        XCTAssertEqual(advice?.message, "alerte VO2max")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DailyAdviceEngineTests`
Expected: FAIL to compile — `advise(...)` doesn't accept a `weightAlert` argument yet.

- [ ] **Step 3: Extend DailyAdviceEngine**

In `HealthCheckShared/Analysis/DailyAdviceEngine.swift`, replace the `advise` function (lines 19-39) with:

```swift
    static func advise(
        readiness: ReadinessScore?,
        loadAlerts: [LoadAlert],
        vo2MaxAlert: LoadAlert?,
        weightAlert: LoadAlert?
    ) -> DailyAdvice? {
        guard let readiness else { return nil }
        let tier = Self.tier(for: readiness.label)

        // Une alerte .warning ne peut affiner le conseil que sous REPOS ou
        // PRUDENCE — jamais sous OPPORTUNITÉ, où elle contredirait le label
        // déjà affiché. Ordre de scan fixe et déterministe : les alertes de
        // charge d'abord (dans leur ordre de production), puis VO2max, puis
        // poids.
        if tier != .opportunite,
           let warning = (loadAlerts + [vo2MaxAlert, weightAlert].compactMap { $0 })
               .first(where: { $0.severity == .warning }) {
            return DailyAdvice(tier: tier, message: warning.message)
        }

        return DailyAdvice(tier: tier, message: Self.genericMessage(for: tier))
    }
```

(Everything else in the file — `tier(for:)`, `genericMessage(for:)` — is unchanged.)

- [ ] **Step 4: Wire DashboardViewModel**

In `HealthCheck/ViewModels/DashboardViewModel.swift`, replace lines 120-136 (from `let vo2Records = ...` through the closing `insights = InsightsEngine.generate(from: inputs)`) with:

```swift
        let vo2Records = try store.records(type: VO2MaxEngine.vo2MaxType, from: d120, to: end)
        inputs.vo2Trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)

        let weightDaily = try dailyAverages(type: "HKQuantityTypeIdentifierBodyMass", from: d30, to: end)
        if let first = weightDaily.first?.value, let last = weightDaily.last?.value {
            inputs.weightDelta30d = last - first
        }
        let weightTrend = WeightEngine.trend(weights: weightDaily, today: end, calendar: calendar)

        let d28 = calendar.date(byAdding: .day, value: -28, to: calendar.startOfDay(for: end))!
        let recentHistory = try store.workouts(from: d28, to: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!)
        let loadAssessment = TrainingLoadMonitor.assess(history: recentHistory, plan: nil,
                                                         readiness: readiness, today: end, calendar: calendar)
        let vo2MaxAlert = VO2MaxEngine.stagnationAlert(trend: inputs.vo2Trend,
                                                        chronicKm: loadAssessment.chronicWeeklyKm)
        let weightSafetyAlert = WeightEngine.safetyAlert(
            trend: weightTrend,
            trainingLoadElevated: loadAssessment.alerts.contains { $0.severity == .warning }
        )
        dailyAdvice = DailyAdviceEngine.advise(readiness: readiness, loadAlerts: loadAssessment.alerts,
                                               vo2MaxAlert: vo2MaxAlert, weightAlert: weightSafetyAlert)

        insights = InsightsEngine.generate(from: inputs)
    }
```

This moves the `weightDaily`/`inputs.weightDelta30d` computation earlier (it now runs right after `inputs.vo2Trend`, instead of after `dailyAdvice`), so `weightTrend` — and therefore `weightSafetyAlert` and the extended `advise(...)` call — has the data it needs. `DashboardViewModel` does **not** load `WeightGoal` — nothing here consumes a goal (see Global Constraints).

- [ ] **Step 5: Write the DashboardViewModel wiring test**

The expected message below must match `WeightEngine.safetyAlert`'s `.warning` string **exactly** — copy it from the actual `HealthCheckShared/Analysis/WeightEngine.swift` produced by Task 2, not by retyping it from this plan text. A single dropped space or swapped `≈`/`~` character here would make this assertion pass against a typo instead of catching one.

Add to `HealthCheckTests/DashboardViewModelTests.swift`, a new test at the end of the class, before its closing brace:

```swift

    @MainActor
    func test_loadWellness_dailyAdviceIncludesWeightSafetyAlertWhenNoOtherWarningPresent() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current

        // Readiness dégradée : FC repos +10 % vs. baseline de 10 jours à
        // 60 bpm → score 40 → label "Récupération conseillée" → palier .repos.
        var records: [HealthRecord] = (1...10).map { daysAgo in
            record(
                type: "HKQuantityTypeIdentifierRestingHeartRate",
                sourceName: "Watch",
                value: 60,
                start: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600)
            )
        }
        records.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch",
                              value: 66, start: calendar.startOfDay(for: now).addingTimeInterval(3600)))

        // Poids : moyenne antérieure (14 jours avant la fenêtre récente)
        // 100 kg, moyenne récente (14 derniers jours) 97 kg -> rythme
        // -1.5 kg/semaine -> 1,5 % du poids corporel/semaine (recentAverage
        // = 97), au-dessus de safeWarningRatePercent (1.0) -> alerte
        // .warning. Aucun historique d'entraînement inséré, donc
        // loadAssessment n'a pas d'alerte .warning (charge non
        // significative) et vo2MaxAlert est nil (aucun échantillon VO2max) —
        // seule l'alerte de poids peut donc remonter dans dailyAdvice.
        records.append(record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch",
                              value: 100, start: calendar.date(byAdding: .day, value: -20, to: now)!))
        records.append(record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch",
                              value: 97, start: calendar.date(byAdding: .day, value: -5, to: now)!))
        try store.insertRecords(records)

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.loadWellness()

        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Rythme de variation du poids au-dessus du repère usuel (≈1 %/semaine).",
                      "le message doit venir de l'alerte de poids, pas du texte générique du palier — sinon la garde ne prouve pas que le câblage passe bien weightAlert")
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DailyAdviceEngineTests`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DashboardViewModelTests`
Expected: PASS, all cases in both suites, including every pre-existing `DashboardViewModelTests` test (none of them assert on the moved `weightDaily`/`inputs.weightDelta30d` block's position, only its result).

- [ ] **Step 7: Commit**

```bash
git add HealthCheckShared/Analysis/DailyAdviceEngine.swift HealthCheckTests/DailyAdviceEngineTests.swift HealthCheck/ViewModels/DashboardViewModel.swift HealthCheckTests/DashboardViewModelTests.swift
git commit -m "feat: fold weight safety alert into the daily advice card"
```

---

### Task 4: BodyViewModel — weight trend, goal, trajectory

**Files:**
- Modify: `HealthCheck/ViewModels/BodyViewModel.swift` (new published properties, wiring in `load(period:)`, two new methods)
- Test: `HealthCheckTests/BodyViewModelTests.swift` (new file — no test currently covers `BodyViewModel`)

**Interfaces:**
- Consumes: `WeightEngine.trend/trajectory/safetyAlert` (Task 2); `WeightGoal`, `WeightGoal.active(in:today:calendar:)`, `HealthStore.saveWeightGoal/deleteWeightGoal/weightGoals` (Task 1).
- Produces: `BodyViewModel.weightGoal: WeightGoal?`, `.weightTrend: WeightTrend?`, `.weightTrajectory: WeightTrajectory?`, `.weightSafetyAlert: LoadAlert?` (all published); `BodyViewModel.createWeightGoal(targetWeightKg: Double, targetDate: Date) throws`; `BodyViewModel.deleteActiveWeightGoal() throws` — consumed by Task 5 (`BodyView`).

- [ ] **Step 1: Write the failing tests**

Create `HealthCheckTests/BodyViewModelTests.swift`:

```swift
import XCTest
@testable import HealthCheck

@MainActor
final class BodyViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    // Poids : moyenne antérieure (14 jours avant la fenêtre récente) 100 kg,
    // moyenne récente (14 derniers jours) 97 kg -> rythme -1.5 kg/semaine ->
    // 1,5 % du poids corporel/semaine (recentAverage = 97), au-dessus de
    // safeWarningRatePercent (1.0).
    private func insertWeightHistory(_ store: HealthStore, now: Date, calendar: Calendar) throws {
        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 100,
                  start: calendar.date(byAdding: .day, value: -20, to: now)!),
            record(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Watch", value: 97,
                  start: calendar.date(byAdding: .day, value: -5, to: now)!)
        ])
    }

    func test_load_weightTrend_computesRateFromFullHistory() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertEqual(viewModel.weightTrend?.weeklyRateKg ?? .nan, -1.5, accuracy: 0.001)
        XCTAssertEqual(viewModel.weightTrend?.direction, .losing)
    }

    func test_load_weightSafetyAlert_alwaysUsesUnelevatedTrainingLoad() throws {
        // BodyViewModel n'a pas de LoadAssessment — trainingLoadElevated
        // doit toujours être false ici, donc le message ne doit jamais
        // mentionner la charge d'entraînement, même à un rythme qui le
        // justifierait sur Accueil.
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertEqual(viewModel.weightSafetyAlert?.severity, .warning)
        XCTAssertFalse(viewModel.weightSafetyAlert?.message.contains("charge d'entraînement") ?? true)
    }

    func test_load_weightTrajectory_nilWithoutActiveGoal() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertNil(viewModel.weightGoal)
        XCTAssertNil(viewModel.weightTrajectory)
    }

    func test_load_weightTrajectory_computedWhenActiveGoalExists() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertWeightHistory(store, now: now, calendar: calendar)
        // target 90 from recentAverage 97 (see insertWeightHistory above),
        // 10 weeks (70 days) remaining -> required (90-97)/10 = -0.7 kg/week ;
        // actual -1.5 -> ratio (-1.5)/(-0.7) ≈ 2.14, clearly > 1.2 -> .tooFast.
        try store.saveWeightGoal(WeightGoal(id: "g", targetWeightKg: 90,
                                            targetDate: calendar.date(byAdding: .day, value: 70, to: now)!,
                                            createdAt: now))

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.load(period: .oneYear)

        XCTAssertEqual(viewModel.weightGoal?.targetWeightKg, 90)
        XCTAssertEqual(viewModel.weightTrajectory?.verdict, .tooFast)
    }

    func test_createWeightGoal_thenDeleteActiveWeightGoal_roundTripsThroughLoad() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: 90, to: now)!

        let viewModel = BodyViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.createWeightGoal(targetWeightKg: 68, targetDate: target)
        try viewModel.load(period: .oneYear)
        XCTAssertEqual(viewModel.weightGoal?.targetWeightKg, 68)

        try viewModel.deleteActiveWeightGoal()
        try viewModel.load(period: .oneYear)
        XCTAssertNil(viewModel.weightGoal)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/BodyViewModelTests`
Expected: FAIL to compile — `weightTrend`/`weightGoal`/`weightTrajectory`/`weightSafetyAlert`/`createWeightGoal`/`deleteActiveWeightGoal` don't exist yet.

- [ ] **Step 3: Wire BodyViewModel**

In `HealthCheck/ViewModels/BodyViewModel.swift`, add four published properties after `weightDelta1y` (currently line 12):

```swift
    @Published private(set) var weightGoal: WeightGoal?
    @Published private(set) var weightTrend: WeightTrend?
    @Published private(set) var weightTrajectory: WeightTrajectory?
    @Published private(set) var weightSafetyAlert: LoadAlert?
```

In `load(period:)`, right after the `all` computation (currently lines 53-58, ending with the closing `)` of `BodyCompositionEngine.dailySnapshots(...)`) and before `let start = period.startDate(now: end, calendar: calendar)` (currently line 59), insert:

```swift

        // Tendance/objectif/trajectoire : à partir de l'historique complet
        // déjà chargé ci-dessus (`all`), jamais de `snapshots` qui varie
        // avec `period` et peut ne couvrir que quelques jours.
        let weightPoints = all.map { TrendPoint(date: $0.day, value: $0.weight) }
        weightTrend = WeightEngine.trend(weights: weightPoints, today: end, calendar: calendar)
        weightGoal = WeightGoal.active(in: try store.weightGoals(), today: end, calendar: calendar)
        weightTrajectory = WeightEngine.trajectory(trend: weightTrend, goal: weightGoal,
                                                    today: end, calendar: calendar)
        // Pas de LoadAssessment disponible ici (contrairement à
        // DashboardViewModel) — toujours false, jamais de duplication du
        // calcul de charge d'entraînement juste pour cette nuance.
        weightSafetyAlert = WeightEngine.safetyAlert(trend: weightTrend, trainingLoadElevated: false)
```

At the end of the file (after `sub(_:_:)`, before the final closing `}`), add:

```swift

    func createWeightGoal(targetWeightKg: Double, targetDate: Date) throws {
        let newGoal = WeightGoal(id: UUID().uuidString, targetWeightKg: targetWeightKg,
                                 targetDate: targetDate, createdAt: now())
        try store.saveWeightGoal(newGoal)
    }

    func deleteActiveWeightGoal() throws {
        guard let weightGoal else { return }
        try store.deleteWeightGoal(id: weightGoal.id)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/BodyViewModelTests`
Expected: PASS, all 5 tests.

- [ ] **Step 5: Commit**

```bash
git add HealthCheck/ViewModels/BodyViewModel.swift HealthCheckTests/BodyViewModelTests.swift
git commit -m "feat: wire weight trend, goal and trajectory into BodyViewModel"
```

---

### Task 5: BodyView — Tendance and Objectif cards

**Files:**
- Modify: `HealthCheck/Views/BodyView.swift`

**Interfaces:**
- Consumes: `BodyViewModel.weightGoal/.weightTrend/.weightTrajectory/.weightSafetyAlert` (Task 4); `BodyViewModel.createWeightGoal(targetWeightKg:targetDate:)`, `.deleteActiveWeightGoal()` (Task 4); `WeightDirection`, `TrajectoryVerdict`, `LoadAlert` (Task 2, `LoadAlert` already used elsewhere in this codebase).
- Produces: nothing consumed by a later task — this is the last task in the plan.

No new automated test: this codebase has no SwiftUI view-level test target, consistent with every other card in this file (`latestCard`, `sankeyCard` have no dedicated view tests either) and with `TrainingView`'s goal-creation form. Verification for this task is: the full test suite still passes (no view-model regression), the build succeeds, and a manual look at the running app.

- [ ] **Step 1: Add the new `@State` properties**

In `HealthCheck/Views/BodyView.swift`, add after `@State private var period: TrendPeriod = .oneYear` (currently line 6):

```swift
    @State private var goalWeightText = ""
    @State private var goalTargetDate = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    @State private var errorMessage: String?
    @State private var showingDeleteGoalConfirmation = false
```

- [ ] **Step 2: Render the two new cards**

`goalCard` falls back to `createGoalForm` whenever `viewModel.weightGoal == nil` — which is also true on a totally empty database (no weigh-ins imported yet). Rendering it unconditionally would show "Créer un objectif" directly below the "Aucune pesée en base" empty state, inviting a goal for data that doesn't exist. Both new cards belong inside the `if let latest = viewModel.latest { ... }` branch (currently lines 14-19, ending right before the `} else {` at line 20), after `sankeyCard`:

```swift
                if let latest = viewModel.latest {
                    latestCard(latest)
                    metricsRow(latest)
                    if let sankey = viewModel.weightSankey {
                        sankeyCard(sankey)
                    }
                    if let trend = viewModel.weightTrend {
                        trendCard(trend)
                    }
                    goalCard
                } else {
```

- [ ] **Step 3: Add the alert and confirmation dialog modifiers**

After `.onChange(of: period) { _, newPeriod in try? viewModel.load(period: newPeriod) }` (currently lines 49-51), before the closing `}` of `body` (currently line 52), insert:

```swift
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Supprimer cet objectif ?", isPresented: $showingDeleteGoalConfirmation,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { deleteWeightGoal() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est irréversible.")
        }
```

- [ ] **Step 4: Add the Tendance card, the Objectif card, and the create-goal form**

Add after `sankeyCard` (currently ending at line 205, before the `// MARK: - Graphiques` comment at line 207):

```swift

    // MARK: - Tendance et objectif de poids

    @ViewBuilder
    private func trendCard(_ trend: WeightTrend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tendance").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(trendLabel(trend.direction)).font(.callout.weight(.semibold))
                Text("\(trend.weeklyRateKg >= 0 ? "+" : "")\(trend.weeklyRateKg.formatted(.number.precision(.fractionLength(2)))) kg/semaine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let alert = viewModel.weightSafetyAlert {
                Label(alert.message,
                     systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }

    private func trendLabel(_ direction: WeightDirection) -> String {
        switch direction {
        case .losing: return "Poids en baisse"
        case .gaining: return "Poids en hausse"
        case .stable: return "Poids stable"
        }
    }

    @ViewBuilder
    private var goalCard: some View {
        if let goal = viewModel.weightGoal {
            VStack(alignment: .leading, spacing: 10) {
                Text("Objectif").font(.title2.bold())
                Text("\(goal.targetWeightKg.formatted(.number.precision(.fractionLength(1)))) kg pour le \(goal.targetDate.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))")
                    .font(.callout.weight(.semibold))
                if let trajectory = viewModel.weightTrajectory {
                    Text(trajectoryLabel(trajectory.verdict))
                        .font(.callout)
                        .foregroundStyle(trajectoryColor(trajectory.verdict))
                    Text("Rythme requis \(trajectory.requiredWeeklyRateKg.formatted(.number.precision(.fractionLength(2)))) kg/semaine · \(Int(trajectory.weeksRemaining.rounded())) semaines restantes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Supprimer l'objectif", role: .destructive) {
                    showingDeleteGoalConfirmation = true
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        } else {
            createGoalForm
        }
    }

    private var createGoalForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Définir un objectif de poids").font(.title2.bold())

            TextField("Poids cible (kg)", text: $goalWeightText)
                .textFieldStyle(.roundedBorder)

            DatePicker("Date cible", selection: $goalTargetDate, in: Date()...,
                      displayedComponents: .date)

            Button("Créer") { createWeightGoal() }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateWeightGoal)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: 460)
    }

    private var parsedGoalWeightKg: Double {
        Double(goalWeightText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canCreateWeightGoal: Bool {
        parsedGoalWeightKg > 0 && goalTargetDate > Date()
    }

    private func createWeightGoal() {
        do {
            try viewModel.createWeightGoal(targetWeightKg: parsedGoalWeightKg, targetDate: goalTargetDate)
            try viewModel.load(period: period)
            goalWeightText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteWeightGoal() {
        do {
            try viewModel.deleteActiveWeightGoal()
            try viewModel.load(period: period)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trajectoryLabel(_ verdict: TrajectoryVerdict) -> String {
        switch verdict {
        case .onTrack: return "En bonne voie"
        case .tooSlow: return "Rythme insuffisant pour atteindre l'objectif à temps"
        case .tooFast: return "Rythme plus rapide que nécessaire"
        }
    }

    private func trajectoryColor(_ verdict: TrajectoryVerdict) -> Color {
        switch verdict {
        case .onTrack: return .green
        case .tooSlow, .tooFast: return .orange
        }
    }
```

- [ ] **Step 5: Regenerate the project and run the full macOS suite**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: PASS, full suite, 0 failures — this task adds no failing test of its own, so this step both confirms the build succeeds (a `View` file's compile errors would fail the whole target build before any test runs) and that nothing upstream regressed.

- [ ] **Step 6: Build the iOS Companion target**

This plan's Tasks 1-3 modify `HealthCheckShared/Models/WeightGoal.swift` (new), `HealthCheckShared/Analysis/WeightEngine.swift` (new), `HealthCheckShared/Store/HealthStore.swift` (modified), and `HealthCheckShared/Analysis/DailyAdviceEngine.swift` (modified) — all four compile into the `HealthCheckCompanion` iOS target too (`project.yml:109`), which is never exercised by the macOS test command above. Confirm it still builds:

Run: `xcrun simctl list devices available` and pick any listed iPhone simulator (do not assume one exists).
Run: `xcodebuild build -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<simulator from the list above>'`

Expected: BUILD SUCCEEDED. Per the repo's `CLAUDE.md`, this command runs **without** `CODE_SIGNING_ALLOWED=NO` — passing it here would leave the host app unsigned and unable to reach the Keychain, which is not what's being checked (this step is a compile check, not a Keychain-dependent test run). Nothing in this plan wires the weight advisor into the Companion UI — this step only confirms the shared module keeps compiling for both targets, matching sub-project 0's stated purpose for `HealthCheckShared/`.

- [ ] **Step 7: Commit**

```bash
git add HealthCheck/Views/BodyView.swift
git commit -m "feat: render weight trend and goal cards on the Corps screen"
```

---

## After the plan

All five tasks land `feat(...)` commits building toward the spec's goals: a rate/direction signal for weight, an optional personal goal with trajectory evaluation, a safety alert that folds into the existing Accueil "Conseil du jour" card as a third source, macOS-only, `HealthCheckShared/` engine placement per sub-project 0's stated purpose (so it compiles for the iOS Companion target too, unwired). Manual verification recommended once the plan is done: create a weight goal on the Corps screen with a real dataset, confirm the trajectory verdict and required-rate math read sensibly, and check that a rapid recent weight change surfaces both on Corps (Tendance card) and, when readiness isn't in the "Excellente"/"Bonne forme" tier, on Accueil's Conseil du jour card.
