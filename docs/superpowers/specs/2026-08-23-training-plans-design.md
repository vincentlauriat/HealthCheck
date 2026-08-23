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

New GRDB migration adding one table:

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

`HealthStore` gains `saveRaceGoal`, `deleteRaceGoal`, `raceGoals()`.
**Active goal** = the goal with the earliest `raceDate >= today`. Past
goals are kept (history) but never planned for.

Swift model `RaceGoal: Codable, FetchableRecord, PersistableRecord`,
mirroring the existing `HealthRecord`/`Workout` patterns.

## 5. TrainingPlanner (pure engine)

`TrainingPlanner.plan(goal:history:today:) -> TrainingPlan`

`history` is the running workouts (`HKWorkoutActivityTypeRunning`) of
the last 90 days, all sources, after `SourcePriorityResolver`-style
dedup is unnecessary (workouts are already unique rows).

### 5.1 Distance fallback

Some historical workouts have `totalDistance = NULL` (old Strava rows).
Estimated distance for any such workout:
`duration_minutes / 7.0` km (7:00 min/km comfortable-pace assumption),
used consistently everywhere a workout distance is read (chronic load,
ACWR, matching). Workouts with a real distance always use it.

### 5.2 Starting point and weekly volumes

- `chronicWeeklyKm` = total km (with fallback) of the last 28 days
  before the current week's Monday, divided by 4.
- `startVolume` = `max(chronicWeeklyKm, 10.0)` km — the floor keeps a
  returning runner on a meaningful base; the chronic reading keeps an
  already-trained runner from being reset to beginner volume.
- Weeks are Monday-based (French convention). `weeksToRace` = number of
  Mondays from the current week's Monday to race week's Monday,
  inclusive of both.
- Volume progression, week by week starting from the current base:
  `W1 = startVolume × 1.10`, then `next = previous × 1.10`, capped so
  the **peak week** (race week − 2… see below) never exceeds
  `raceDistance × 1.5` km (25.5 km for 17 km).
- **Taper**: race week − 1 = peak × 0.75; race week = peak × 0.5,
  race excluded (the race is not a planned session).
- If `weeksToRace <= 2` (goal created very late) all remaining weeks
  are taper weeks at `startVolume × 0.75` — never ramp into a race.

Worked example (Vincent today: chronic ≈ 12.6/4 → floor 10 → start
max(3.15, 10) = 10 — note the 28-day window catches only this first
week back, hence the floor doing its job; 5 weeks):
W1 11 km → W2 12.1 → W3 13.3 (peak) → W4 10.0 (taper 0.75) →
W5 6.7 + race. Values are illustrative of the formulas, not constants
in code; tests pin the formulas.

*(Peak is always `raceWeek − 2`; with 5 weeks that makes 3 build weeks.)*

### 5.3 Sessions of a week

Every non-taper week has 3 core sessions plus 1 optional:

| Session | Share of week volume | Prescription |
|---|---|---|
| Long run | 45 %, growth capped at +2 km/week, absolute cap `min(14, raceDistance × 0.8)` km | Endurance zone, "la séance qui fait le 17 km" |
| Hills | 25 % | Rolling/hilly route; weekly climb target from 100 m (W1) growing linearly to `min(300, raceElevation × 0.75)` m at peak week |
| Base endurance | remainder (≈30 %) | Easy zone |
| Optional short run | 30 min easy, **not counted in the week's target volume** (once executed it counts in *executed* load like any workout, §6) | Only shown when the week's 3 core sessions are all done or ahead of schedule |

Taper weeks: long run capped at `raceDistance × 0.4`, no hill session
in race week, all sessions easy zone except one 15-min leg-opener the
week of the race.

### 5.4 Heart-rate zones

`hrMax` = highest heart-rate **sample** recorded during any running
workout interval in the last 180 days (join `health_record`
HeartRate rows to workout intervals); fallback if none: 190.
Zones: easy = 60–75 % of hrMax, endurance = 70–80 %, hills hard
effort = 85–92 %. Prescriptions are phrased as bpm ranges in the UI.
No pace targets in v1 (objective is comfort, not time).

## 6. TrainingLoadMonitor (pure engine)

`TrainingLoadMonitor.assess(history:readiness:today:) -> LoadAssessment`

- `acute` = km of the last 7 days (fallback rule §5.1);
  `chronic` = km of the last 28 days / 4.
- `acwr = acute / chronic` (nil when chronic < 3 km — too little data,
  no ratio shown).
- Alerts: `acwr > 1.3` → « Vous progressez trop vite — réduisez cette
  semaine » (severity: warning). `acwr < 0.8` with a goal active and
  ≥ 2 build weeks remaining → « Vous pouvez en faire un peu plus »
  (severity: info).
- Day suggestion: if today's planned session is Hills or Long run and
  the readiness score (existing engine) is `< 50`, suggest swapping
  with an easy day: « Forme du jour basse — intervertissez avec une
  séance facile ». Purely advisory; the plan itself does not move.
- **No catch-up rule**: a missed week (executed < 50 % of target)
  re-bases the next weeks from the *executed* chronic load, never
  inflates a following week beyond the ×1.10 cap.

## 7. Matching planned vs executed

Within the current week (Monday-based), executed running workouts are
matched to planned sessions greedily: sort executed by distance
descending, planned by target distance descending, pair in order. A
session is « done » when its matched workout's distance is ≥ 70 % of
target (or ≥ 70 % of target climb for the hills session when route
elevation data exists; distance rule otherwise). Unmatched extra
workouts count toward week volume but are labeled « hors plan ». The
remaining days of the week redistribute nothing — undone sessions just
stay visible as « à faire ».

## 8. UI — « Entraînement » screen

New sidebar row in the Analyse group (icon `figure.run`, between
Séances and Corps). French, vouvoiement. States:

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

- `HealthCheck/Models/RaceGoal.swift` — model + table constants.
- `HealthCheck/Store/HealthStore+RaceGoals.swift` — migration + CRUD.
- `HealthCheck/Engine/TrainingPlanner.swift` — §5 (TrainingPlan,
  PlannedWeek, PlannedSession value types included).
- `HealthCheck/Engine/TrainingLoadMonitor.swift` — §6 (LoadAssessment).
- `HealthCheck/Engine/SessionMatcher.swift` — §7.
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

- The hills « done » check uses distance when no route elevation is
  available (most non-GPX workouts).
- hrMax from observed samples underestimates true max for a runner who
  never pushed hard in the window — zones err on the easy side, which
  matches the objective.
- Weekly targets in km treat hilly km and flat km identically; the
  dedicated hills session is the equalizer, not a grade-adjusted
  metric.
- One objective type in v1 (« finir confortablement »); the enum and
  table are ready for more.
