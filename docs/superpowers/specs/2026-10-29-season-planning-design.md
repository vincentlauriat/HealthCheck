# HealthCheck — Season planning

Date: 2026-10-29. Extends `2026-08-23-training-plans-design.md`; where the
two disagree, this document wins.

## 1. Why

The v1 planner served one race at a time and guarded the runner with hard
ceilings. A real season broke it:

- Route des 4 Châteaux (15 Nov, 18 km, 300 m), Cross du Figaro (29 Nov,
  10 km), then Restonica GT20K (9 Jul 2027, 17 km, 650 m). The nearest race
  won, so the app would plan Chevreuse and ignore Corte.
- The second goal could not even be entered: the creation form only showed
  on the empty screen.
- On a 36-week horizon the ramp reached its ceiling in about ten weeks and
  stayed flat for six months, with no recovery week.
- Ceilings sized for a road 17 km: weekly volume ≤ 1.5 × distance, long run
  ≤ 14 km, hill session ≤ 300 m D+. A 650 m trail could never be prepared.

The guiding rule of this change: **the engine advises, it does not forbid.**
Ceilings follow the race and the runner's measured level; a ceiling the
user chooses is applied as is, and the load monitor says what it thinks.

## 2. Model

`RaceGoal` gains:

- `priority: Priority` — `.main` (the race the plan prepares) or `.tuneUp`
  (a race on the way). Default `.main`, so existing goals behave as before.
- `peakWeeklyKmOverride: Double?` — user-chosen weekly ceiling.
- `effortKm = distanceKm + elevationGainM / 100`, `isTrail` (≥ 30 m/km).

Store: two columns added by an idempotent `ALTER TABLE` migration that reads
`PRAGMA table_info`; legacy rows read back as `.main` with no override.

Selection: `RaceGoal.active` returns the nearest future `.main` race, else
the nearest future race. `RaceGoal.tuneUps(for:in:)` returns every `.tuneUp`
race before the main one, past races included, so past weeks keep their
shape after the race is run.

## 3. Planner

`TrainingPlanner.plan(goal:tuneUps:history:hrMax:today:calendar:)`.
Anchoring (§5.2bis of the v1 spec) is unchanged.

New roles: `.recovery`, `.tuneUp`. New session kind: `.tuneUpRace`.
`PlannedWeek.tuneUp` carries the race of that week whatever its role.

Within the ramp zone (up to the peak):

1. Tune-up week (not the peak): target `max(lastRampTarget × 0.85, race +
   3 km)`; sessions race, leg opener, easy run. Owes a recovery week when the
   race is ≥ 15 km-effort.
2. Recovery week (not the peak, not the week before it): owed after a long
   tune-up, or after three consecutive build weeks. Target
   `lastRampTarget × 0.7`; long run × 0.7; no hard or optional session.
3. Otherwise a build/peak week, as in v1, ramping from `lastRampTarget`.

Recovery and tune-up weeks never update `lastRampTarget` nor the long-run
seed: the ramp resumes where it stopped. A tune-up in the peak, taper or
maintenance weeks keeps the role and replaces the long run.

Ceilings:

- Volume: override if set, else `max(effortKm × 1.5, anchorBaseKm)`.
- Long run: race distance up to 21.1 km, else `min(0.75 × distance, 32)`.
- Hills: `0.75 × race D+`, no absolute ceiling.
- Trail long run carries the race gradient (half in recovery/taper).

## 4. Monitor

- Overshoot (> 125 %): same threshold, wording states the gap and what
  protects instead of "stick to the plan".
- Recovery week in progress: info, "it is intended".
- Override above 1.3 × the computed ceiling: info, never a refusal.
- `hasCollapsed` keeps ignoring non-ramp weeks; recovery and tune-up weeks
  drop by construction.

## 5. UI

Mac « Entraînement »: a « Saison » section lists upcoming races with their
place in the plan, per-race removal, and an « Ajouter une course » form with
the priority picker and the optional weekly ceiling. Week rows show the race
of tune-up weeks and the week's total prescribed D+. The plan explainer
mentions recovery weeks, integrated races and the ceiling's origin.

Companion: no protocol change. The week role string carries the race name
(« Course de préparation · Route des 4 Châteaux »).

## 6. Tests

`SeasonPlanningTests` (engine, monitor) and `RaceGoalStoreTests` (round
trip, legacy migration). Every new guard was seen failing under a mutation
(19 mutants, all killed) before being accepted.
