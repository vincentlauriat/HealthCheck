# Season planning — handoff

Branch: `feature/season-planning` (commit ab20128 and this note).
Design: `docs/superpowers/specs/2026-10-29-season-planning-design.md`.
Formulas: `docs/METHODOLOGY.md` §11.3, §11.6, §11.9, §12.

## Done

- Engine (`TrainingPlanner`, `TrainingLoadMonitor`, `RaceGoal`): race
  priority (main / tune-up), tune-up weeks, recovery weeks (3 + 1 and after
  races of 15 km-effort or more), ceilings on effort km and measured base,
  user weekly ceiling applied as is, trail long runs with climb, no 300 m
  hill ceiling, long run up to race distance (half and under).
- Verified on Linux (Swift 6.1, Foundation only): `TrainingPlannerTests`,
  `TrainingLoadMonitorTests`, `SessionMatcherTests`, `SeasonPlanningTests`,
  106 tests green. 19 mutants on the new guards, all killed.
- Written but **not compiled** (no Xcode, no GRDB, no Combine on Linux):
  `HealthStore` migration and read/write, `TrainingViewModel`,
  `TrainingPlanProvider`, `TrainingView` (season section, add race form,
  per-race removal), `RaceGoalStoreTests` (round trip, legacy migration).

## To do on the Mac

1. `git fetch && git checkout feature/season-planning`, then `xcodegen generate`
   (new test file `HealthCheckTests/SeasonPlanningTests.swift`).
2. `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
   and fix any compile error in the four unverified files above.
3. `xcodebuild test -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=<existing>'`
   (no companion code changed; the week role string now carries the race name).
4. Mutation check for the store, per the repo rule: drop the
   `migrateRaceGoalSeasonColumns` call and watch
   `test_legacyRaceGoalTable_isMigratedWithoutLosingTheGoal` fail; drop
   `priority` from the INSERT and watch
   `test_saveRaceGoal_roundTripsPriorityAndOverride` fail.
5. Run the app: delete the old goal, create Restonica GT20K (main, 2027-07-09,
   17 km, 650 m), Route des 4 Châteaux (tune-up, 2026-11-15, 18 km, 300 m),
   Cross du Figaro (tune-up, 2026-11-29, 10 km, 0 m). Expected: week of
   9 Nov is a tune-up week (≥ 21 km), 16 Nov recovery, 23 Nov tune-up,
   ramp resumes 30 Nov, peak week of 21 Jun 2027 at 35.25 km.
6. Open the PR.

## Open ideas (not started)

- Edit a goal's priority or ceiling in place (today: delete and recreate).
- Pace targets from recent efforts once the objective enum grows past
  `finishComfortable`.
- Elevation capture so trail climb can be verified, not only prescribed.
