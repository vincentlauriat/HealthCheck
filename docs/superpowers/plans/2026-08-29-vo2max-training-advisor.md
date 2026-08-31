# VO2max Training Advisor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn VO2max from a passive trend chart into three active advisor signals: a trend verdict, a dedicated interval session in the training plan, and a stagnation alert.

**Architecture:** A new pure engine `HealthCheckShared/Analysis/VO2MaxEngine.swift` (30-day vs. 90-day-prior window comparison) feeds `TrainingPlanner` (new `SessionKind.vo2MaxIntervals`, alternated with `.hills` on ramp weeks), `InsightsEngine` (replaces its ad-hoc first/last-sample comparison), and a new `TrainingViewModel.vo2MaxStatus` published property rendered in a new card on `TrainingView`. macOS-only for this sub-project — the engine lives in the shared module but no Companion (iPhone) UI is wired in this plan.

**Tech Stack:** Swift, XCTest, XcodeGen-generated Xcode project, GRDB-backed `HealthStore`.

**Spec:** `docs/superpowers/specs/2026-08-29-vo2max-training-advisor-design.md`

## Global Constraints

- Every engine follows the existing `Analysis/` convention: `enum` of `static func`s, no clock/calendar reads inside the engine, `today`/`calendar` always explicit parameters, raw `[HealthRecord]`/`[Workout]` as input, never a pre-aggregated DTO.
- Any test written specifically to catch a bug must be seen to fail against that exact bug before being accepted (repo convention, `CLAUDE.md`).
- macOS test command: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- Run `xcodegen generate` after adding `HealthCheckShared/Analysis/VO2MaxEngine.swift` (new file in an already-declared source path) before the first build that references it.
- Never touch `Companion/` or `CompanionTests/` — this sub-project is macOS-only for UI; the engine is shared but nothing wires it into the iPhone app in this plan.
- Meaningful VO2max delta threshold: `1.0` mL/min·kg. Recent window: last 30 days (inclusive of `today`). Prior window: the 90 days immediately before that (day −120 to day −30). Chronic-load threshold for the stagnation alert: `TrainingLoadMonitor.meaningfulChronicKm` (`8.0` km/week, referenced not duplicated).
- VO2max intervals heart-rate range: `hrRange(0.90, 0.97, hrMax:)` — above the existing `.hills` "hard" range of `hrRange(0.85, 0.92, hrMax:)`.
- Ramp weeks (`.build`/`.peak`) alternate `.hills` (even `weekIndexInRamp`, starting at 0) / `.vo2MaxIntervals` (odd `weekIndexInRamp`). `.taper`, `.raceWeek`, `.currentWeekClosing` never get `.vo2MaxIntervals`.
- **Compile-atomic tasks:** `SessionKind` (Task 2) and `InsightInputs` (Task 3) are each matched non-exhaustively in more than one file. Every task in this plan that changes such a type updates **every** call site in the same commit — never split a type change from its call sites across two tasks, or the module won't compile in between.

---

### Task 1: VO2MaxEngine (pure engine)

**Files:**
- Create: `HealthCheckShared/Analysis/VO2MaxEngine.swift`
- Test: `HealthCheckTests/VO2MaxEngineTests.swift`
- Modify: `docs/METHODOLOGY.md` (new subsection `### 11.8`, after the existing `### 11.7` at line 759, before the `---` separator at line 781)

**Interfaces:**
- Produces: `enum VO2MaxVerdict: Equatable { case rising, stable, declining }`; `struct VO2MaxTrend: Equatable { let recentAverage: Double; let priorAverage: Double; let delta: Double; let verdict: VO2MaxVerdict }`; `struct VO2MaxStatus: Equatable { let trend: VO2MaxTrend?; let alert: LoadAlert? }`; `VO2MaxEngine.trend(records: [HealthRecord], today: Date, calendar: Calendar) -> VO2MaxTrend?`; `VO2MaxEngine.stagnationAlert(trend: VO2MaxTrend?, chronicKm: Double) -> LoadAlert?`. `LoadAlert` already exists in `HealthCheckShared/Analysis/TrainingLoadMonitor.swift`.

- [ ] **Step 1: Write the failing tests**

Create `HealthCheckTests/VO2MaxEngineTests.swift`:

```swift
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
        XCTAssertEqual(trend?.recentAverage, 43.0, accuracy: 0.01)
        XCTAssertEqual(trend?.priorAverage, 40.0, accuracy: 0.01)
        XCTAssertEqual(trend?.delta, 3.0, accuracy: 0.01)
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
        XCTAssertEqual(trend?.recentAverage, 43.0, accuracy: 0.01) // the 999 sample must not enter the average
    }

    func test_trend_averagesMultipleSamplesPerWindow() {
        let records = [vo2("2026-08-18", 42.0), vo2("2026-08-20", 44.0), vo2("2026-06-01", 40.0)]
        let trend = VO2MaxEngine.trend(records: records, today: date("2026-08-23"), calendar: calendar)
        XCTAssertEqual(trend?.recentAverage, 43.0, accuracy: 0.01) // (42 + 44) / 2
    }

    func test_stagnationAlert_nilWhenTrendIsNil() {
        XCTAssertNil(VO2MaxEngine.stagnationAlert(trend: nil, chronicKm: 20))
    }

    func test_stagnationAlert_nilWhenRising() {
        let trend = VO2MaxTrend(recentAverage: 43, priorAverage: 40, delta: 3, verdict: .rising)
        XCTAssertNil(VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 20))
    }

    func test_stagnationAlert_nilBelowChronicLoadThreshold() {
        let trend = VO2MaxTrend(recentAverage: 40, priorAverage: 40, delta: 0, verdict: .stable)
        XCTAssertNil(VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 7.9))
    }

    func test_stagnationAlert_infoWhenStableAboveChronicLoadThreshold() {
        let trend = VO2MaxTrend(recentAverage: 40, priorAverage: 40, delta: 0, verdict: .stable)
        let alert = VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 8.0)
        XCTAssertEqual(alert?.severity, .info)
    }

    func test_stagnationAlert_warningWhenDecliningAboveChronicLoadThreshold() {
        let trend = VO2MaxTrend(recentAverage: 38, priorAverage: 40, delta: -2, verdict: .declining)
        let alert = VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: 8.0)
        XCTAssertEqual(alert?.severity, .warning)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/VO2MaxEngineTests`
Expected: FAIL to compile — `VO2MaxEngine`, `VO2MaxTrend`, `VO2MaxVerdict` do not exist yet.

- [ ] **Step 3: Write the implementation**

Create `HealthCheckShared/Analysis/VO2MaxEngine.swift`:

```swift
import Foundation

enum VO2MaxVerdict: Equatable {
    case rising
    case stable
    case declining
}

struct VO2MaxTrend: Equatable {
    let recentAverage: Double
    let priorAverage: Double
    let delta: Double
    let verdict: VO2MaxVerdict
}

struct VO2MaxStatus: Equatable {
    let trend: VO2MaxTrend?
    let alert: LoadAlert?
}

/// Interprète la VO2max comme un signal d'entraînement plutôt qu'une simple
/// courbe : tendance sur deux fenêtres glissantes (30 jours récents contre
/// 90 jours juste avant), et alerte quand elle stagne malgré une charge
/// soutenue. Comme tous les autres moteurs, pur et sans horloge propre.
enum VO2MaxEngine {
    static let vo2MaxType = "HKQuantityTypeIdentifierVO2Max"
    static let recentWindowDays = 30
    static let priorWindowDays = 90
    static let meaningfulDeltaThreshold = 1.0

    static func trend(records: [HealthRecord], today: Date, calendar: Calendar) -> VO2MaxTrend? {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        let recentStart = calendar.date(byAdding: .day, value: -recentWindowDays, to: endExclusive)!
        let priorStart = calendar.date(byAdding: .day, value: -(recentWindowDays + priorWindowDays),
                                       to: endExclusive)!

        let samples = records.filter { $0.type == vo2MaxType }
        let recentValues = samples
            .filter { $0.startDate >= recentStart && $0.startDate < endExclusive }
            .map(\.value)
        let priorValues = samples
            .filter { $0.startDate >= priorStart && $0.startDate < recentStart }
            .map(\.value)
        guard !recentValues.isEmpty, !priorValues.isEmpty else { return nil }

        let recentAverage = recentValues.reduce(0, +) / Double(recentValues.count)
        let priorAverage = priorValues.reduce(0, +) / Double(priorValues.count)
        let delta = recentAverage - priorAverage
        let verdict: VO2MaxVerdict
        if delta >= meaningfulDeltaThreshold {
            verdict = .rising
        } else if delta <= -meaningfulDeltaThreshold {
            verdict = .declining
        } else {
            verdict = .stable
        }
        return VO2MaxTrend(recentAverage: recentAverage, priorAverage: priorAverage,
                           delta: delta, verdict: verdict)
    }

    static func stagnationAlert(trend: VO2MaxTrend?, chronicKm: Double) -> LoadAlert? {
        guard let trend, trend.verdict != .rising else { return nil }
        guard chronicKm >= TrainingLoadMonitor.meaningfulChronicKm else { return nil }
        if trend.verdict == .declining {
            return LoadAlert(severity: .warning, message: "VO2max en baisse malgré une charge d'entraînement soutenue — signe possible de surentraînement ou de récupération insuffisante.")
        }
        return LoadAlert(severity: .info, message: "VO2max stable malgré une charge d'entraînement soutenue — un palier normal, ou un signal pour varier l'intensité.")
    }
}
```

- [ ] **Step 4: Run `xcodegen generate`, then run the tests to verify they pass**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/VO2MaxEngineTests`
Expected: PASS, all 13 tests.

- [ ] **Step 5: Document the engine in METHODOLOGY.md**

In `docs/METHODOLOGY.md`, insert a new subsection immediately after `### 11.7 Ce que ce moteur ne fait délibérément pas` (before the `---` separator that follows it), matching the doc's existing style (prose + code block + line references):

```markdown
### 11.8 Alternance côtes / intervalles VO2max — `VO2MaxEngine`

Une semaine de montée en charge (`.build`/`.peak`) sur deux remplace sa
séance de côtes par une séance d'intervalles VO2max, dans une zone
cardiaque quasi-maximale (`hrRange(0.90, 0.97, hrMax:)`, au-dessus de la
zone `hard` 85–92 % des côtes). L'alternance est pilotée par
`weekIndexInRamp` — la position (base 0) de la semaine parmi toutes les
semaines `.build`/`.peak`, calculée par `TrainingPlanner.plan(...)` : index
pair → côtes, index impair → intervalles (`TrainingPlanner.swift`). La
première semaine de montée en charge (index 0) reste toujours en côtes.
`.taper`, `.raceWeek` et la semaine de clôture ne reçoivent jamais
d'intervalles.

`VO2MaxEngine` (`HealthCheckShared/Analysis/VO2MaxEngine.swift`) interprète
séparément la VO2max mesurée comme un signal de progression :

```swift
recentWindowDays = 30            // fenêtre récente, jusqu'à aujourd'hui inclus
priorWindowDays = 90             // fenêtre antérieure, immédiatement avant
meaningfulDeltaThreshold = 1.0   // mL/min·kg
```

`trend(records:today:calendar:)` retourne `nil` si l'une des deux fenêtres
n'a aucun échantillon — pas de seuil de volume minimal, les échantillons
VO2max étant déjà rares par nature (estimés par l'Apple Watch sur certaines
sorties GPS). `stagnationAlert(trend:chronicKm:)` retourne une alerte
(`.info` si stable, `.warning` si en baisse) seulement quand la charge
chronique dépasse `TrainingLoadMonitor.meaningfulChronicKm` (8,0 km/semaine,
la même constante que le moniteur de charge, référencée et non dupliquée) —
en dessous, la stagnation n'est pas surprenante et ne mérite pas d'alerte.
```

- [ ] **Step 6: Commit**

```bash
git add HealthCheckShared/Analysis/VO2MaxEngine.swift HealthCheckTests/VO2MaxEngineTests.swift docs/METHODOLOGY.md HealthCheck.xcodeproj
git commit -m "feat(analysis): add VO2MaxEngine trend and stagnation-alert logic"
```

---

### Task 2: TrainingPlanner — `vo2MaxIntervals` session and its alternation with hills

**Files:**
- Modify: `HealthCheckShared/Analysis/TrainingPlanner.swift`
- Modify: `HealthCheck/Views/TrainingView.swift` (label switches only — required for the module to keep compiling once `SessionKind` gains a case; the new card is Task 5)
- Modify: `HealthCheck/Import/TrainingPlanProvider.swift` (label switches only, same reason — this file serializes the plan for Companion and has its own exhaustive `SessionKind` switches)
- Test: `HealthCheckTests/TrainingPlannerTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 — this task is independent of `VO2MaxEngine`.
- Produces: `SessionKind.vo2MaxIntervals` case; `TrainingPlanner.sessions(role:targetKm:previousLongKm:climbTargetM:goal:hrMax:weekIndexInRamp:)` — `weekIndexInRamp: Int? = nil` (defaulted so every pre-existing call site, in this file and in tests, keeps compiling and keeps its current behaviour unchanged).

- [ ] **Step 1: Write the failing tests**

Add to `HealthCheckTests/TrainingPlannerTests.swift`, after `test_sessions_everySessionInEveryWeek_hasNonEmptyRationale` (the last `sessions`-focused test, around line 448):

```swift
    func test_sessions_weekIndexInRampOdd_usesVo2MaxIntervalsInsteadOfHills() {
        let week = TrainingPlanner.sessions(role: .build, targetKm: 20, previousLongKm: 10,
                                            climbTargetM: 100, goal: goal(), hrMax: 190,
                                            weekIndexInRamp: 1)
        XCTAssertFalse(week.contains { $0.kind == .hills })
        let interval = week.first { $0.kind == .vo2MaxIntervals }
        XCTAssertNotNil(interval)
        XCTAssertEqual(interval?.targetKm ?? -1, 20 * TrainingPlanner.hillsShare, accuracy: 0.001)
        XCTAssertEqual(interval?.targetClimbM, 0)
        XCTAssertEqual(interval?.hrRange, TrainingPlanner.hrRange(0.90, 0.97, hrMax: 190))
        XCTAssertFalse(interval?.rationale.isEmpty ?? true)
    }

    func test_sessions_weekIndexInRampEven_keepsHills() {
        let week = TrainingPlanner.sessions(role: .build, targetKm: 20, previousLongKm: 10,
                                            climbTargetM: 100, goal: goal(), hrMax: 190,
                                            weekIndexInRamp: 0)
        XCTAssertTrue(week.contains { $0.kind == .hills })
        XCTAssertFalse(week.contains { $0.kind == .vo2MaxIntervals })
    }

    func test_sessions_weekIndexInRampOmitted_defaultsToHills() {
        // Backward-compat: every pre-existing call site in this file omits
        // the parameter and must keep producing hills, unchanged.
        let week = TrainingPlanner.sessions(role: .build, targetKm: 20, previousLongKm: 10,
                                            climbTargetM: 100, goal: goal(), hrMax: 190)
        XCTAssertTrue(week.contains { $0.kind == .hills })
    }

    func test_sessions_taperWeek_ignoresAnOddWeekIndexInRamp_staysHills() {
        // Role gates the alternation, not just index parity — a taper week
        // must never receive vo2MaxIntervals even with an odd index.
        let week = TrainingPlanner.sessions(role: .taper, targetKm: 15, previousLongKm: 10,
                                            climbTargetM: 50, goal: goal(), hrMax: 190,
                                            weekIndexInRamp: 1)
        XCTAssertTrue(week.contains { $0.kind == .hills })
        XCTAssertFalse(week.contains { $0.kind == .vo2MaxIntervals })
    }

    func test_plan_goldenCase_alternatesHillsAndVo2MaxIntervalsAcrossRampWeeks() {
        // Same golden fixture as test_plan_goldenCase_volumesAndRolesFollowTheRamp:
        // roles [.build, .build, .peak, .taper, .raceWeek] → ramp indices 0,1,2.
        let plan = TrainingPlanner.plan(goal: goal(), history: comebackHistory, hrMax: 190,
                                        today: date("2026-08-23"), calendar: calendar)
        let planned = plan.weeks.filter { $0.role != .currentWeekClosing }
        func hillsOrIntervalsKind(_ week: PlannedWeek) -> SessionKind? {
            week.sessions.first { $0.kind == .hills || $0.kind == .vo2MaxIntervals }?.kind
        }
        // index 0 (.build) hills, index 1 (.build) intervals, index 2 (.peak)
        // hills, index 3 (.taper) hills, index 4 (.raceWeek) neither (legOpener).
        XCTAssertEqual(planned.map(hillsOrIntervalsKind),
                       [.hills, .vo2MaxIntervals, .hills, .hills, nil])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/TrainingPlannerTests`
Expected: FAIL to compile — `SessionKind.vo2MaxIntervals` and the `weekIndexInRamp` parameter do not exist yet.

- [ ] **Step 3: Add the `SessionKind` case and the `rationale` branch**

In `HealthCheckShared/Analysis/TrainingPlanner.swift`, in the `SessionKind` enum (currently lines 12-18), add the new case:

```swift
enum SessionKind: Equatable {
    case longRun
    case hills
    case vo2MaxIntervals
    case baseEndurance
    case optionalEasy
    case legOpener
}
```

In `rationale(for:isTaper:)` (currently lines 357-372), add a case before `.baseEndurance`:

```swift
        case .vo2MaxIntervals:
            return "Les efforts proches du maximum sont ce qui fait progresser la VO2max le plus efficacement — les côtes travaillent la force, ceci travaille la capacité aérobie."
```

- [ ] **Step 4: Add the `weekIndexInRamp` parameter and the alternation to `sessions(...)`**

In `sessions(role:targetKm:previousLongKm:climbTargetM:goal:hrMax:)` (currently lines 374-422), change the signature and the hills branch:

```swift
    static func sessions(role: WeekRole, targetKm: Double, previousLongKm: Double,
                         climbTargetM: Double, goal: RaceGoal, hrMax: Double,
                         weekIndexInRamp: Int? = nil) -> [PlannedSession] {
        let isTaper = role == .taper || role == .raceWeek
        var longKm = min(targetKm * longRunShare,
                         previousLongKm + longRunWeeklyGrowthKm,
                         min(14.0, goal.distanceKm * 0.8))
        if isTaper { longKm = min(longKm, goal.distanceKm * 0.4) }

        let easy = hrRange(0.60, 0.75, hrMax: hrMax)
        let endurance = hrRange(0.70, 0.80, hrMax: hrMax)
        let hard = hrRange(0.85, 0.92, hrMax: hrMax)
        let intervals = hrRange(0.90, 0.97, hrMax: hrMax)

        var result = [
            PlannedSession(kind: .longRun, targetKm: longKm, targetMinutes: nil,
                           targetClimbM: 0, hrRange: isTaper ? easy : endurance,
                           note: isTaper
                               ? "Sortie longue allégée — restez très à l'aise."
                               : "Sortie longue : la séance qui construit votre distance. Allure conversation.",
                           rationale: rationale(for: .longRun, isTaper: isTaper))
        ]

        if role == .raceWeek {
            result.append(PlannedSession(kind: .legOpener, targetKm: 0, targetMinutes: 15,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Déverrouillage : 15 min souples avec deux ou trois accélérations courtes.",
                                         rationale: rationale(for: .legOpener, isTaper: isTaper)))
        } else {
            let usesIntervals: Bool
            if let index = weekIndexInRamp, role == .build || role == .peak {
                usesIntervals = index % 2 == 1
            } else {
                usesIntervals = false
            }
            if usesIntervals {
                result.append(PlannedSession(kind: .vo2MaxIntervals, targetKm: targetKm * hillsShare,
                                             targetMinutes: nil, targetClimbM: 0, hrRange: intervals,
                                             note: "Fractionné : répétitions courtes et rapides, séparées de récupérations. L'intensité compte plus que la distance — visez la zone indiquée.",
                                             rationale: rationale(for: .vo2MaxIntervals, isTaper: isTaper)))
            } else {
                result.append(PlannedSession(kind: .hills, targetKm: targetKm * hillsShare,
                                             targetMinutes: nil, targetClimbM: climbTargetM,
                                             hrRange: isTaper ? endurance : hard,
                                             note: "Parcours vallonné, visez environ \(Int(climbTargetM.rounded())) m de dénivelé positif.",
                                             rationale: rationale(for: .hills, isTaper: isTaper)))
            }
        }

        let used = result.reduce(0) { $0 + $1.targetKm }
        result.append(PlannedSession(kind: .baseEndurance,
                                     targetKm: max(targetKm - used, minimumBaseKm),
                                     targetMinutes: nil, targetClimbM: 0, hrRange: easy,
                                     note: "Endurance fondamentale : facile, vraiment facile.",
                                     rationale: rationale(for: .baseEndurance, isTaper: isTaper)))

        if !isTaper {
            result.append(PlannedSession(kind: .optionalEasy, targetKm: 0, targetMinutes: 30,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Optionnelle : 30 min faciles, seulement si les trois autres séances sont faites et que vous vous sentez bien.",
                                         rationale: rationale(for: .optionalEasy, isTaper: isTaper)))
        }
        return result
    }
```

- [ ] **Step 5: Pass `weekIndexInRamp` from `plan(...)`'s two call sites**

In `plan(goal:history:hrMax:today:calendar:)`, the maintenance-branch call site (currently lines 258-259, inside `if mondays.count <= 2`) — this branch never produces `.build`/`.peak` roles, so pass `nil` explicitly:

```swift
                let weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                            climbTargetM: climb, goal: goal, hrMax: hrMax,
                                            weekIndexInRamp: nil)
```

The main ramp-loop call site (currently lines 312-313) — `i` already IS the ramp index for `i <= peakIndex` (the loop's `.build`/`.peak` weeks are exactly indices `0...peakIndex`, in order):

```swift
            let weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                        climbTargetM: climb, goal: goal, hrMax: hrMax,
                                        weekIndexInRamp: i <= peakIndex ? i : nil)
```

- [ ] **Step 6: Keep `TrainingView.swift` and `TrainingPlanProvider.swift` compiling**

`SessionKind` is now non-exhaustively matched in two other files. In `HealthCheck/Views/TrainingView.swift`, `sessionLabel(_:)` (currently lines 383-391) and `intensityLabel(_:)` (currently lines 411-418):

```swift
    private func sessionLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "Sortie longue"
        case .hills: return "Côtes"
        case .vo2MaxIntervals: return "Intervalles VO2max"
        case .baseEndurance: return "Endurance"
        case .optionalEasy: return "Optionnelle"
        case .legOpener: return "Déverrouillage"
        }
    }
```

```swift
    private func intensityLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "endurance"
        case .hills, .vo2MaxIntervals: return "intensité"
        case .baseEndurance, .optionalEasy: return "récupération active"
        case .legOpener: return "réveil"
        }
    }
```

In `HealthCheck/Import/TrainingPlanProvider.swift`, `sessionLabel(_:)` (currently lines 93-101) and `intensityLabel(_:)` (currently lines 121-128) — same text, this file serializes the plan sent to Companion:

```swift
    private func sessionLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "Sortie longue"
        case .hills: return "Côtes"
        case .vo2MaxIntervals: return "Intervalles VO2max"
        case .baseEndurance: return "Endurance"
        case .optionalEasy: return "Optionnelle"
        case .legOpener: return "Déverrouillage"
        }
    }
```

```swift
    private func intensityLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "endurance"
        case .hills, .vo2MaxIntervals: return "intensité"
        case .baseEndurance, .optionalEasy: return "récupération active"
        case .legOpener: return "réveil"
        }
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: PASS, full suite (no regression in any pre-existing test — every prior call to `sessions(...)` omits `weekIndexInRamp` and keeps defaulting to `.hills`).

- [ ] **Step 8: Commit**

```bash
git add HealthCheckShared/Analysis/TrainingPlanner.swift HealthCheck/Views/TrainingView.swift HealthCheck/Import/TrainingPlanProvider.swift HealthCheckTests/TrainingPlannerTests.swift
git commit -m "feat(training): alternate hills and VO2max intervals across ramp weeks"
```

---

### Task 3: InsightsEngine + DashboardViewModel — trend-based VO2max insight

**Files:**
- Modify: `HealthCheckShared/Analysis/InsightsEngine.swift`
- Modify: `HealthCheck/ViewModels/DashboardViewModel.swift`
- Test: `HealthCheckTests/AnalysisEngineTests.swift` (the `InsightsEngineTests` class already there, not a separate file)
- Test: `HealthCheckTests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes: `VO2MaxTrend`, `VO2MaxVerdict`, `VO2MaxEngine.trend(records:today:calendar:)` (Task 1).
- Produces: `InsightInputs.vo2Trend: VO2MaxTrend?` (replaces `vo2Latest`/`vo2ThreeMonthsAgo`).

**Both files land in this one task, and neither half is committed alone.** `DashboardViewModel.swift` is the *only* production call site that constructs an `InsightInputs` and is the sole place in the whole codebase (outside `InsightsEngine.swift` itself, confirmed by search) that references `vo2Latest`/`vo2ThreeMonthsAgo`. Committing the `InsightInputs` field rename without updating it — or vice versa — leaves the module non-compiling.

- [ ] **Step 1: Write the failing/updated tests**

In `HealthCheckTests/AnalysisEngineTests.swift`, replace `test_vo2Progress_detected` (currently lines 83-92) with:

```swift
    func test_vo2Progress_detected() {
        var inputs = InsightInputs()
        inputs.vo2Trend = VO2MaxTrend(recentAverage: 42.5, priorAverage: 40.8, delta: 1.7, verdict: .rising)

        let insights = InsightsEngine.generate(from: inputs)

        XCTAssertEqual(insights.first?.title, "VO₂ max en progression")
        XCTAssertEqual(insights.first?.sentiment, .positive)
        XCTAssertEqual(insights.first?.message, "40.8 → 42.5 ml/kg/min sur les trois derniers mois — votre capacité aérobie s'améliore.")
    }

    func test_vo2Stable_producesNoInsight() {
        var inputs = InsightInputs()
        inputs.vo2Trend = VO2MaxTrend(recentAverage: 41.0, priorAverage: 40.8, delta: 0.2, verdict: .stable)

        XCTAssertTrue(InsightsEngine.generate(from: inputs).isEmpty)
    }

    func test_vo2Declining_producesNoInsight() {
        // The insight only ever celebrates progress — a decline is not this
        // engine's concern (the stagnation alert on TrainingViewModel covers it).
        var inputs = InsightInputs()
        inputs.vo2Trend = VO2MaxTrend(recentAverage: 38.0, priorAverage: 40.0, delta: -2.0, verdict: .declining)

        XCTAssertTrue(InsightsEngine.generate(from: inputs).isEmpty)
    }

    func test_vo2NilTrend_producesNoInsight() {
        XCTAssertTrue(InsightsEngine.generate(from: InsightInputs()).isEmpty)
    }
```

In `HealthCheckTests/DashboardViewModelTests.swift`, add after `test_loadWellness_scoresTodayAgainstPersonalBaseline` (currently lines 107-137), before the closing `}` of the class:

```swift

    @MainActor
    func test_loadWellness_vo2MaxRising_producesInsightViaTheSharedEngine() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current

        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 43.0,
                  start: calendar.date(byAdding: .day, value: -5, to: now)!),
            record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40.0,
                  start: calendar.date(byAdding: .day, value: -60, to: now)!)
        ])

        let viewModel = DashboardViewModel(store: store,
                                           resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
                                           now: { now })
        try viewModel.loadWellness()

        XCTAssertTrue(viewModel.insights.contains { $0.title == "VO₂ max en progression" })
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/InsightsEngineTests`
Expected: FAIL to compile — `InsightInputs.vo2Trend` does not exist yet (`vo2Latest`/`vo2ThreeMonthsAgo` are still the old fields), so both this target and `DashboardViewModelTests` fail to build.

- [ ] **Step 3: Replace the `InsightInputs` fields and the generation branch**

In `HealthCheckShared/Analysis/InsightsEngine.swift`, in `InsightInputs` (currently lines 14-23), replace:

```swift
    var vo2Latest: Double?
    var vo2ThreeMonthsAgo: Double?
```

with:

```swift
    var vo2Trend: VO2MaxTrend?
```

In `generate(from:)` (currently lines 87-94), replace:

```swift
        if let latest = inputs.vo2Latest, let older = inputs.vo2ThreeMonthsAgo, latest - older >= 1 {
            insights.append(Insight(
                systemImage: "lungs.fill",
                title: "VO₂ max en progression",
                message: String(format: "%.1f → %.1f ml/kg/min sur les trois derniers mois — votre capacité aérobie s'améliore.", older, latest),
                sentiment: .positive
            ))
        }
```

with:

```swift
        if let trend = inputs.vo2Trend, trend.verdict == .rising {
            insights.append(Insight(
                systemImage: "lungs.fill",
                title: "VO₂ max en progression",
                message: String(format: "%.1f → %.1f ml/kg/min sur les trois derniers mois — votre capacité aérobie s'améliore.", trend.priorAverage, trend.recentAverage),
                sentiment: .positive
            ))
        }
```

- [ ] **Step 4: Update the only production call site — `DashboardViewModel.swift`**

In `HealthCheck/ViewModels/DashboardViewModel.swift`, in `loadWellness()`'s guard block (currently lines 66-70), rename `d90` to `d120` and change its offset (`d90` is used nowhere else in this file — confirmed by search — so this rename is safe):

```swift
        let end = now()
        guard
            let d30 = calendar.date(byAdding: .day, value: -30, to: end),
            let d120 = calendar.date(byAdding: .day, value: -120, to: end),
            let d7 = calendar.date(byAdding: .day, value: -7, to: end)
        else { return }
```

Replace the VO2max block (currently lines 119-121):

```swift
        let vo2Daily = try dailyAverages(type: "HKQuantityTypeIdentifierVO2Max", from: d90, to: end)
        inputs.vo2Latest = vo2Daily.last?.value
        inputs.vo2ThreeMonthsAgo = vo2Daily.first?.value
```

with:

```swift
        let vo2Records = try store.records(type: "HKQuantityTypeIdentifierVO2Max", from: d120, to: end)
        inputs.vo2Trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: PASS, full suite — this single run covers both `InsightsEngineTests` (including the three pre-existing cases in the class that don't touch `vo2Trend` at all: `test_elevatedRestingHR_producesWarningFirst`, `test_sleepDebt_detectedBelowSevenHours`, `test_smallVariationsProduceNoInsight`) and `DashboardViewModelTests`.

- [ ] **Step 6: Commit**

```bash
git add HealthCheckShared/Analysis/InsightsEngine.swift HealthCheck/ViewModels/DashboardViewModel.swift HealthCheckTests/AnalysisEngineTests.swift HealthCheckTests/DashboardViewModelTests.swift
git commit -m "refactor(analysis): drive the VO2max insight from VO2MaxTrend"
```

---

### Task 4: TrainingViewModel — publish `vo2MaxStatus`

**Files:**
- Modify: `HealthCheck/ViewModels/TrainingViewModel.swift`
- Test: `HealthCheckTests/TrainingViewModelTests.swift`

**Interfaces:**
- Consumes: `VO2MaxEngine.trend(records:today:calendar:)`, `VO2MaxEngine.stagnationAlert(trend:chronicKm:)` (Task 1); `TrainingPlanner.chronicWeeklyKm(history:today:calendar:)` (already exists, unchanged).
- Produces: `TrainingViewModel.vo2MaxStatus: VO2MaxStatus?` (published) — consumed by Task 5 (`TrainingView`).

- [ ] **Step 1: Write the failing tests**

Add to `HealthCheckTests/TrainingViewModelTests.swift`, a new helper near `hrRecord` (currently lines 30-34):

```swift
    func vo2Record(_ day: String, value: Double) -> HealthRecord {
        HealthRecord(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", device: nil,
                    unit: "mL/min·kg", value: value, startDate: date(day), endDate: date(day),
                    creationDate: date(day))
    }
```

Add a new `MARK` section at the end of the class, before its closing brace:

```swift

    // MARK: - VO2max

    func test_load_vo2MaxStatus_computesTrendFromStoredRecords() throws {
        let store = try HealthStore(path: ":memory:")
        try store.insertRecords([
            vo2Record("2026-08-20", value: 43.0), // dans les 30 derniers jours (today = 2026-08-23)
            vo2Record("2026-06-20", value: 40.0)  // dans la fenêtre antérieure (30 à 120 jours avant)
        ])
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertEqual(vm.vo2MaxStatus?.trend?.verdict, .rising)
        XCTAssertEqual(vm.vo2MaxStatus?.trend?.recentAverage ?? -1, 43.0, accuracy: 0.01)
    }

    func test_load_vo2MaxStatus_nilTrend_whenNoVo2Samples() throws {
        let store = try HealthStore(path: ":memory:")
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertNotNil(vm.vo2MaxStatus) // the status wrapper itself is always present
        XCTAssertNil(vm.vo2MaxStatus?.trend)
    }

    func test_load_vo2MaxStatus_populatedWithoutActiveGoal() throws {
        // Carry-over of the same regression the load-monitor already guards
        // against (test_load_withoutGoal_computesRawAcwrAssessment): the
        // no-goal branch must not skip vo2MaxStatus either.
        let store = try HealthStore(path: ":memory:")
        try store.insertRecords([
            vo2Record("2026-08-20", value: 43.0),
            vo2Record("2026-06-20", value: 40.0)
        ])
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertNil(vm.goal)
        XCTAssertEqual(vm.vo2MaxStatus?.trend?.verdict, .rising)
    }

    func test_load_vo2MaxStatus_stagnationAlert_whenStableUnderSustainedLoad() throws {
        let store = try HealthStore(path: ":memory:")
        try store.saveRaceGoal(goal("2026-09-27", createdAt: "2026-08-17"))
        // 4 × 10 km within the last 28 days → chronic 10 km/week, above the
        // 8.0 km/week meaningfulChronicKm threshold.
        try store.insertWorkouts([
            run("2026-08-01", km: 10.0), run("2026-08-08", km: 10.0),
            run("2026-08-15", km: 10.0), run("2026-08-22", km: 10.0)
        ])
        try store.insertRecords([
            vo2Record("2026-08-20", value: 41.0),
            vo2Record("2026-06-20", value: 40.5) // delta 0.5 → stable
        ])
        let vm = TrainingViewModel(store: store, calendar: calendar, now: { self.date("2026-08-23") })

        try vm.load()

        XCTAssertEqual(vm.vo2MaxStatus?.trend?.verdict, .stable)
        XCTAssertEqual(vm.vo2MaxStatus?.alert?.severity, .info)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/TrainingViewModelTests`
Expected: FAIL to compile — `TrainingViewModel.vo2MaxStatus` does not exist yet.

- [ ] **Step 3: Add the property and the computation**

In `HealthCheck/ViewModels/TrainingViewModel.swift`, add the published property after `assessment` (currently line 14):

```swift
    @Published private(set) var vo2MaxStatus: VO2MaxStatus?
```

Add two constants after `defaultHRMax` (currently line 36):

```swift
    private static let vo2MaxType = "HKQuantityTypeIdentifierVO2Max"
    private static let vo2LookbackDays = 120
```

In `load(readiness:)`, right after `let history = try store.workouts(from: historyStart, to: end)` (currently line 73) and before the `guard let activeGoal else` block (currently line 80), insert:

```swift

        let vo2LookbackStart = calendar.date(byAdding: .day, value: -Self.vo2LookbackDays, to: end)!
        let vo2Records = try store.records(type: Self.vo2MaxType, from: vo2LookbackStart, to: end)
        let vo2Trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)
        let chronicKm = TrainingPlanner.chronicWeeklyKm(history: history, today: end, calendar: calendar)
        vo2MaxStatus = VO2MaxStatus(trend: vo2Trend,
                                    alert: VO2MaxEngine.stagnationAlert(trend: vo2Trend, chronicKm: chronicKm))
```

This sits before the `guard let activeGoal else { ...; return }` branch, so `vo2MaxStatus` is computed exactly once and is populated in both the active-goal and no-goal paths — matching how `assessment` is already computed in the no-goal branch (line 83) without needing separate duplicated code.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/TrainingViewModelTests`
Expected: PASS, all cases including every pre-existing test in the file (none of them assert on `vo2MaxStatus`, so none should change).

- [ ] **Step 5: Commit**

```bash
git add HealthCheck/ViewModels/TrainingViewModel.swift HealthCheckTests/TrainingViewModelTests.swift
git commit -m "feat(training): publish vo2MaxStatus from TrainingViewModel"
```

---

### Task 5: TrainingView — VO2max card

**Files:**
- Modify: `HealthCheck/Views/TrainingView.swift`

**Interfaces:**
- Consumes: `TrainingViewModel.vo2MaxStatus: VO2MaxStatus?` (Task 4); `VO2MaxVerdict`, `LoadAlert` (Task 1, already used elsewhere in this file for `loadSection`).
- Produces: nothing consumed by a later task — this is the last task in the plan.

No new automated test: this codebase has no SwiftUI view-level test target (`TrainingViewModelTests` covers the view model, not rendering), consistent with every other card in this file (`loadSection`, `goalCard`, etc. have no dedicated view tests either). Verification for this task is: the full test suite still passes (no view model regression), the build succeeds, and a manual look at the running app.

- [ ] **Step 1: Add the VO2max card function**

In `HealthCheck/Views/TrainingView.swift`, add a new function after `loadSection` (currently ending at line 454, before the next `// MARK:` section):

```swift

    // MARK: - VO2max

    @ViewBuilder
    private func vo2MaxSection(_ status: VO2MaxStatus) -> some View {
        if let trend = status.trend {
            VStack(alignment: .leading, spacing: 8) {
                Text("VO2max").font(.title2.bold())
                VStack(alignment: .leading, spacing: 2) {
                    Text(vo2VerdictLabel(trend.verdict)).font(.callout.weight(.semibold))
                    Text("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg (\(trend.delta >= 0 ? "+" : "")\(trend.delta.formatted(.number.precision(.fractionLength(1)))) sur 3 mois)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let alert = status.alert {
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
    }

    private func vo2VerdictLabel(_ verdict: VO2MaxVerdict) -> String {
        switch verdict {
        case .rising: return "VO2max : en hausse"
        case .stable: return "VO2max : stable"
        case .declining: return "VO2max : en baisse"
        }
    }
```

- [ ] **Step 2: Render the card in both branches of `body`**

In `body` (currently lines 16-43), the card is shown regardless of whether a goal is active — insert right after each `loadSection(assessment)` call:

```swift
                if let goal = viewModel.goal, let plan = viewModel.plan {
                    goalCard(goal: goal, plan: plan)
                    if let next = nextGoalAfterActive {
                        Text("Objectif suivant : \(next.name), le \(raceDateText(next.raceDate)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let progress = viewModel.progress {
                        thisWeekSection(progress, hrMax: plan.hrMax)
                    }
                    if let assessment = viewModel.assessment {
                        loadSection(assessment)
                    }
                    if let vo2Status = viewModel.vo2MaxStatus {
                        vo2MaxSection(vo2Status)
                    }
                    upcomingWeeksSection(plan)
                    deleteSection
                } else {
                    emptyState
                    if let assessment = viewModel.assessment {
                        loadSection(assessment)
                    }
                    if let vo2Status = viewModel.vo2MaxStatus {
                        vo2MaxSection(vo2Status)
                    }
                }
```

- [ ] **Step 3: Regenerate the project and run the full macOS suite**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: PASS, full suite, 0 failures — this task adds no failing test of its own, so this step both confirms the build succeeds (a `View` file's compile errors would fail the whole target build before any test runs) and that nothing upstream regressed.

- [ ] **Step 4: Commit**

```bash
git add HealthCheck/Views/TrainingView.swift HealthCheck.xcodeproj
git commit -m "feat(training): render the VO2max card on the Entraînement screen"
```

---

## After the plan

All five tasks land `feat(...)`/`refactor(...)` commits directly building toward the spec's three goals (verdict + numeric delta, dedicated interval session, stagnation alert), macOS-only, `HealthCheckShared/` engine placement per sub-project 0's stated purpose. Manual verification recommended once the plan is done: create or reuse a race goal with enough VO2max history to see the new card, and check a ramp week's session list shows `.vo2MaxIntervals` on an odd `weekIndexInRamp`.
