# HealthCheck — Training plans (race goals)

**Date:** 2026-08-23
**Status:** validated in discussion, awaiting written-spec review
**Decisions taken with Vincent:** deterministic rule engine (no templates,
no LLM) · generic race goals (first: Paris-Versailles, 2026-09-27, 17 km,
+400 m) · objective "finish comfortably" · 3 core sessions per week + 1
optional · plan re-anchors on executed workouts

## 1. Context and motivation

Vincent resumed running this week (~12.6 km over 3 runs after a break
since mid-June) and races Paris-Versailles on 2026-09-27: 17 km, +400 m
of climb, 5 full training weeks away. The risk profile of a comeback is
asymmetric: under-training costs comfort, over-training costs the race
(injury). The app is uniquely placed to steer this because the iOS
companion now delivers every workout and daily metric automatically —
the plan can react to what Vincent actually ran, not what he intended
to run.

**Direct beneficiaries:** the weekly volume decision (how much is enough,
how much is too much) and the daily decision (is today a hard day).

## 2. Goals / non-goals

**Goals**

- A race goal the user creates in-app (name, date, distance, elevation
  gain, objective type).
- A deterministic 100%-local plan: weekly targets and sessions from
  today to race day, computed from the goal and the real workout
  history.
- Continuous re-anchoring: executed workouts (companion sync) mark
  sessions done and re-base next weeks' volumes.
- Injury guardrails: capped weekly progression, acute:chronic workload
  ratio alerts, readiness-informed hard-day suggestions, no catch-up
  after a missed week.

**Non-goals (deferred, not designed here)**

- Pace-based prescriptions (min/km targets) and time-objective plans —
  the "target a time" objective type is out of scope; the enum leaves
  room for it.
- Multi-sport plans (cycling, swimming). Running only.
- Calendar/reminder integration, notifications.
- Editing individual planned sessions by hand.
- Capturing elevation (altitude in the exchange protocol, `<ele>` in
  GPX, ascent computation with GPS smoothing) — see §6.1.
- More than one active goal at a time (nearest future race wins;
  others are ignored until it passes).

## 3. Architecture overview

```
race_goal (SQLite)      workout history (existing)     readiness (existing)
      │                          │                            │
      ▼                          ▼                            │
TrainingPlanner  ──────────►  TrainingPlan (weeks, sessions)  │
      ▲                          │                            │
      │                          ▼                            ▼
      └──────────  TrainingLoadMonitor (ACWR, alerts, day suggestions)
                                 │
                                 ▼
                    TrainingViewModel → TrainingView (sidebar « Entraînement »)
```

Both engines are pure (inputs in, values out, no I/O, no clock reads —
`today` is always a parameter). Persistence is limited to the goal: the
plan is recomputed on load and after each companion sync, so plan and
reality cannot drift apart and no plan schema ever needs migrating.

## 4. Data model

One new table. **The project has no `DatabaseMigrator`** — the schema
is created by `CREATE TABLE IF NOT EXISTS` statements inside
`HealthStore.init(path:)`. The new table follows that pattern exactly:
one more `try db.execute(sql:)` in the same `queue.write` block, no
migration machinery introduced.

```sql
CREATE TABLE race_goal (
    id TEXT PRIMARY KEY,            -- UUID string
    name TEXT NOT NULL,             -- "Paris-Versailles"
    raceDate TEXT NOT NULL,         -- ISO8601 day, e.g. "2026-09-27"
    distanceKm REAL NOT NULL,
    elevationGainM REAL NOT NULL,
    objective TEXT NOT NULL,        -- "finishComfortable" (only value in v1)
    createdAt TEXT NOT NULL
);
```

`HealthStore` gains `saveRaceGoal(_:)`, `deleteRaceGoal(id:)`, and
`raceGoals() throws -> [RaceGoal]`, written like every other store
method: raw SQL through `queue().read`/`queue().write`, `Row.fetchAll`,
manual row→struct mapping, ISO8601 dates via the store's existing
`isoFormatter`.

**Active goal** = the goal with the earliest `raceDate >= today`. Past
goals are kept (history) but never planned for. The selection is a pure
function over the fetched array, not SQL — it is unit-testable and the
table is tiny.

Swift model `struct RaceGoal: Equatable` with a plain memberwise init —
**not** `Codable`/`FetchableRecord`/`PersistableRecord`: no existing
model conforms to those, the store maps rows by hand, and `id` is a
UUID string generated at creation (unlike `HealthRecord`/`Workout`,
whose ids are SHA256 dedup keys — a race goal has nothing to dedup).

## 5. TrainingPlanner (pure engine)

```swift
enum TrainingPlanner {
    static func plan(goal: RaceGoal,
                     history: [Workout],
                     today: Date,
                     calendar: Calendar) -> TrainingPlan
}
```

Engines in this project are `enum`s of `static func`s living in
`HealthCheck/Analysis/`, never read the clock internally, and take
`calendar` as a parameter rather than using `.current` — these two
follow that convention.

`history` is the running workouts (`HKWorkoutActivityTypeRunning`) of
the last 90 days, all sources, after `SourcePriorityResolver`-style
dedup is unnecessary (workouts are already unique rows).

### 5.1 Distance fallback

Some historical workouts have `totalDistance = NULL` (old Strava rows).
Estimated distance for any such workout:
`duration_minutes / 7.0` km (7:00 min/km comfortable-pace assumption),
used consistently everywhere a workout distance is read (chronic load,
ACWR, matching). Workouts with a real distance always use it.

### 5.2bis What is anchored, and what tracks reality

**This section exists because the first implementation got it wrong in three
ways at once, all with the same root: a quantity that should be fixed once was
recomputed from `today` on every rebuild.** The plan is recomputed on every
load (§3) — that is what keeps plan and reality in step — but recomputation
must reproduce the plan's history, not rewrite it.

| Quantity | Anchored to | Why |
|---|---|---|
| The week sequence (which Mondays the plan spans) | `goal.createdAt`'s week, applying the §5.2 start-week rule **at creation time** | Otherwise the horizon shrinks as the race nears and the plan falls into the ≤2-week maintenance branch, destroying the taper (see below) |
| A week's role (build / peak / taper / raceWeek) | position relative to `raceMonday` | Peak is always race−2; roles must not depend on how many weeks remain to be *rebuilt* |
| A week's target volume | the load measured **strictly before that week's Monday** | A target must not move while the week is being run |
| The ≤2-week maintenance branch | the horizon **at creation** | It exists for a goal genuinely created inside two weeks, not for the tail of a longer plan |

Consequences that are requirements, not side effects:

- **A week's target is fixed for the duration of that week.** Computing the
  ramp base from a window that includes the current week makes the target chase
  what was executed: each run raises the same week's target, so the plan moves
  daily with no user action, and — worse — `executed > target × 1.25` becomes
  arithmetically unreachable, disabling the over-training alert entirely. That
  alert is the feature's whole purpose (§1's asymmetry: under-training costs
  comfort, over-training costs the race).
- **Past weeks must reproduce their historical targets.** Computing the arc
  means folding forward from the first build week, each week's target derived
  from load as of that week's start and capped at `× f` against the previous
  week's target. This is deterministic from the goal plus the workout history —
  no new persistence — and it is what makes `peakVolume` still available when
  the peak week is in the past and the taper needs it.
- **Re-anchoring happens at week boundaries, not continuously.** That is what
  §2's "continuous re-anchoring" and §6's no-catch-up rule ("re-bases the
  *next* weeks") both actually describe.

### 5.2 Starting point and weekly volumes

- **One chronic definition, used by both engines** (§6 reads the same
  numbers — divergent windows would let the planner prescribe what the
  monitor flags): `chronicWeeklyKm` = total km (with fallback) of the
  **last 28 days ending today, inclusive**, divided by 4.
  `acuteKm` = total km of the last 7 days ending today, inclusive.
- `startVolume` = `max(chronicWeeklyKm, acuteKm, 10.0)` km — the floor
  keeps a returning runner on a meaningful base, the acute reading
  credits the comeback week already underway, and the chronic reading
  keeps an already-trained runner from being reset to beginner volume.
- Weeks are Monday-based (French convention).
- **Start week rule.** The current week is always *displayed* (executed
  sessions, so the user sees where they stand) but receives new targets
  only if at least 3 days remain in it (enough for the 3 core sessions).
  Otherwise it is shown as `.currentWeekClosing` — executed only, no
  targets — and the ramp's first build week is the following Monday.
  This matters on the very first plan: created on a Sunday, a
  "week 1" with zero remaining days would be a target nobody can hit
  and would poison the ×f chain.
- `weeksToRace` = number of Mondays from the **first build week's**
  Monday to race week's Monday, inclusive of both.
- Volume progression, week by week starting from the current base:
  `W1 = startVolume × f`, then `next = previous × f`, where
  `f = 1.15` while `startVolume < raceDistance` (comeback ramp — a
  returning runner rebuilding toward a known level tolerates slightly
  faster progression) and `f = 1.10` otherwise; capped so the **peak
  week** (race week − 2… see below) never exceeds `raceDistance × 1.5`
  km (25.5 km for 17 km). The ACWR guard (§6) remains the runtime
  safety net either way.
- **Taper**: race week − 1 = peak × 0.75; race week = peak × 0.5,
  race excluded (the race is not a planned session).
- If `weeksToRace <= 2` (goal created very late) all remaining weeks
  are taper weeks at `startVolume × 0.75` — never ramp into a race.

Worked example — the real case, pinned as a golden test. Today
Sunday 2026-08-23, race Sunday 2026-09-27, 17 km / +400 m. The current
week (Mon 08-17) has 0 days left → `.currentWeekClosing`; the ramp
starts Mon 08-24, giving 5 planned weeks. chronic ≈ 3.15, acute 12.6 →
`startVolume` = max(3.15, 12.6, 10) = 12.6; `f` = 1.15 (12.6 < 17);
longest run of the last 14 days = 5.6 km.

| Week (Monday) | Volume | Long run | Role |
|---|---|---|---|
| 08-24 | 14.5 | 8.1 | build |
| 08-31 | 16.7 | 10.0 | build |
| 09-07 | 19.2 | 11.5 | **peak** (race − 2) |
| 09-14 | 14.4 | 6.8 | taper ×0.75 |
| 09-21 | 9.6 | 6.8 | race week ×0.5, race 09-27 |

Long-run chain: min(60 % of volume, previous + 2.5, cap 13.6).
Values illustrate the formulas; the test pins them to ±0.05 km.

*(Peak is always `raceWeek − 2`; with 5 weeks that makes 3 build weeks.)*

### 5.3 Sessions of a week

Every non-taper week has 3 core sessions plus 1 optional:

| Session | Share of week volume | Prescription |
|---|---|---|
| Long run | up to 60 % of week volume, growth capped at +2.5 km/week from the longest run of the last 14 days (default base 5 km), absolute cap `min(14, raceDistance × 0.8)` km | Endurance zone, "la séance qui fait le 17 km" — the 60 % share is deliberate on 3-session weeks: at comeback volumes a 45 % share would peak the long run near 6 km, useless for a 17 km objective |
| Hills | 25 % | Rolling/hilly route; weekly climb target from 100 m (W1) growing linearly to `min(300, raceElevation × 0.75)` m at peak week |
| Base endurance | remainder (volume − long − hills, minimum 3 km) | Easy zone |
| Optional short run | 30 min easy, **not counted in the week's target volume** (once executed it counts in *executed* load like any workout, §6) | Only shown when the week's 3 core sessions are all done or ahead of schedule |

Taper weeks: long run capped at `raceDistance × 0.4`, no hill session
in race week, all sessions easy zone except one 15-min leg-opener the
week of the race.

### 5.4 Heart-rate zones

`hrMax` = highest heart-rate sample of the last 180 days, read with a
**single indexed query, no join** — the store holds ~1.8 M rows and a
range-join of HeartRate against workout intervals on screen load is
exactly the class of problem the recent perf pass removed:

```sql
SELECT MAX(value) FROM health_record
WHERE type = 'HKQuantityTypeIdentifierHeartRate'
  AND startDate >= :cutoff;
```

Fallback if the query returns NULL: 190.
Zones: easy = 60–75 % of hrMax, endurance = 70–80 %, hills hard
effort = 85–92 %. Prescriptions are phrased as bpm ranges in the UI.
No pace targets in v1 (objective is comfort, not time).

## 6. TrainingLoadMonitor (pure engine)

```swift
enum TrainingLoadMonitor {
    static func assess(history: [Workout],
                       plan: TrainingPlan?,
                       readiness: ReadinessScore?,
                       today: Date,
                       calendar: Calendar) -> LoadAssessment
}
```

`readiness` arrives as an already-computed `ReadinessScore?` (the
existing `HealthScoreEngine.readiness(sleep:restingHeartRate:hrv:activity:)`
returns one, and the view model composes its components exactly as
`DashboardViewModel` already does). The monitor never recomputes it and
never touches the store — it stays a pure function.

- `acute` and `chronic`: the §5.2 definitions, verbatim — one reading
  shared by both engines.
- `acwr = acute / chronic`, **nil unless the history is meaningful**:
  at least 3 of the last 4 weeks contain a run, or `chronic >= 8` km.
  A comeback mechanically shows a huge ratio (12.6 / 3.15 ≈ 4.0 for
  Vincent on day one) — that is arithmetic, not danger, and showing it
  as a warning next to a plan card prescribing a ramp would be
  self-contradictory. Below the gate the card reads « Reprise en cours
  — l'indicateur de charge s'activera après 3 semaines régulières ».
- **Alerts follow the plan when a goal is active.** The planner already
  caps progression at `f` per week; a ramp that respects the plan is by
  construction safe, so raw ACWR must not fire against it. With an
  active goal, alerts compare executed against *planned* week volume:
  - executed > 125 % of the week's target → « Vous dépassez le plan —
    tenez-vous-en aux séances prévues » (warning);
  - executed < 50 % of target with ≤ 2 days left in the week →
    « Semaine en retard — elle ne sera pas rattrapée la semaine
    suivante » (info, restating the no-catch-up rule).
  The ACWR value is still *displayed* when the gate above passes
  (informative), but it does not drive the alert.
- **Without an active goal** (feature used as a plain load monitor),
  raw ACWR drives the alerts: `> 1.3` → « Vous progressez trop vite »
  (warning); `< 0.8` → « Vous pouvez en faire un peu plus » (info).
- Day suggestion: if today's planned session is Hills or Long run and
  the readiness score (existing engine) is `< 50`, suggest swapping
  with an easy day: « Forme du jour basse — intervertissez avec une
  séance facile ». Purely advisory; the plan itself does not move.
- **No catch-up rule**: a missed week (executed < 50 % of target)
  re-bases the next weeks from the *executed* chronic load, never
  inflates a following week beyond the ×1.10 cap.

### 6.1 Climb is prescriptive only (verified against the data)

Checked on the real store before writing this: the `workout` table has
no elevation column, `ExchangeRoutePoint` carries lat/lon/timestamp
only, and the GPX files written by the companion contain **no `<ele>`
element**. No elevation figure exists anywhere in the pipeline, and the
companion is the primary data path from now on.

Therefore the hills session **prescribes** a climb target and nothing
ever verifies it: its done-check uses distance (§7), like any other
session, and the climb figure is displayed as a coaching instruction
(« parcours vallonné, visez ~200 m de D+ »). No test asserts on climb
data, because no real workout can reach such a branch — the exact trap
that cost a review round in the companion project.

Capturing altitude is a worthwhile follow-up but is **not** in this
scope: `CLLocation.altitude` is already in hand on the iOS side, so the
transport is trivial, but a naive sum of positive deltas over noisy GPS
inflates ascent by 2-3×. Doing it right needs a smoothing pass with its
own tests — a task of its own, later.

## 7. Matching planned vs executed

Within the current week (Monday-based), executed running workouts are
matched to planned sessions greedily: sort executed by distance
descending, planned by target distance descending, pair in order. A
session is « done » when its matched workout's distance is ≥ 70 % of
target. This is the rule for every session type including hills — see
§6.1: no elevation data exists to check a climb against. Unmatched extra
workouts count toward week volume but are labeled « hors plan ». The
remaining days of the week redistribute nothing — undone sessions just
stay visible as « à faire ».

## 8. UI — « Entraînement » screen

New `case training` in the existing `SidebarSelection` enum, with a
row in the `Section("Analyse")` group between Séances and Corps
(`Label("Entraînement", systemImage: "target")` — `figure.run` is
already taken by Séances). Cards reuse `Theme.swift`'s `MetricCard`
styling so the screen matches the rest of the app. French, vouvoiement. States:

- **No active goal**: empty state + « Créer un objectif » form
  (name, date, distance km, climb m — objective fixed to « Finir
  confortablement » in v1).
- **Active goal**:
  - Goal card: name, race date + countdown (« J−34 »), distance / D+,
    « Semaine 2 sur 5 ».
  - This week: the 3(+1) sessions as rows — type, target (km or climb),
    bpm range, done/todo badge, « hors plan » chip for extras.
  - Load card: acute vs chronic bars, ACWR value with the alert copy
    of §6 when triggered, plus the day suggestion when active.
  - Next weeks: one compact row per remaining week (volume, long-run
    km, climb target), taper weeks labeled « affûtage ».
- Refresh: reloads on `companionSyncGeneration`, `withingsViewModel`
  untouched; follows the existing load-once + `onChange` pattern in
  `ContentView`.

## 9. Error handling

| Case | Behaviour |
|---|---|
| No running history at all | Plan starts at the 10 km floor; zones fall back to hrMax 190. |
| Race date passed | Goal excluded from planning; screen back to empty state (history kept in table). |
| Race < 2 weeks away at creation | Taper-only plan (§5.2); UI shows an honest caption « Trop tard pour progresser — plan de maintien ». |
| Two future goals | Nearest date is active; the other is listed, greyed, unplanned. |
| Store write fails on goal creation | Alert with the store error; no partial state (single-row insert). |

## 10. Code structure

- `HealthCheck/Models/RaceGoal.swift` — model.
- `HealthCheck/Store/HealthStore.swift` — one more `CREATE TABLE IF
  NOT EXISTS` in `init(path:)` plus the three CRUD methods (same file
  as the other store methods, matching the existing layout).
- `HealthCheck/Analysis/TrainingPlanner.swift` — §5 (TrainingPlan,
  PlannedWeek, PlannedSession value types included).
- `HealthCheck/Analysis/TrainingLoadMonitor.swift` — §6
  (LoadAssessment).
- `HealthCheck/Analysis/SessionMatcher.swift` — §7.
- `HealthCheck/ViewModels/TrainingViewModel.swift` — composition,
  load-once, `hasLoaded`.
- `HealthCheck/Views/TrainingView.swift` — §8.
- `ContentView` — sidebar row + `onChange` reload wiring.

## 11. Testing strategy

Engine-first, mirroring the project:

- **Planner**: ×1.10 cap respected across all weeks; peak at race−2;
  taper factors; long-run caps (45 %, +2 km/week, absolute);
  hill-climb ramp; 10 km floor; late-goal (≤2 weeks) taper-only path;
  determinism (same inputs → identical plan); the real 5-week
  Vincent case as a golden test.
- **Load monitor**: ACWR at the 0.8 / 1.3 boundaries; nil below the
  3 km chronic floor; duration-fallback distances; readiness-triggered
  day suggestion; no-catch-up re-basing after a missed week.
- **Matcher**: greedy pairing, 70 % done threshold, « hors plan »
  labeling, empty week.
- **Store**: migration, CRUD round-trip, active-goal selection
  (nearest future, past excluded).
- **View model**: empty state vs active goal, reload on sync
  generation.
- UI untested (thin), like the other screens.

## 12. Known limitations (accepted)

- Climb is never verified, only prescribed (§6.1). Vincent knows
  whether he ran hills; the app does not.
- hrMax from observed samples underestimates true max for a runner who
  never pushed hard in the window — zones err on the easy side, which
  matches the objective.
- Weekly targets in km treat hilly km and flat km identically; the
  dedicated hills session is the equalizer, not a grade-adjusted
  metric.
- One objective type in v1 (« finir confortablement »); the enum and
  table are ready for more.
