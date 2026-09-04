# Architecture — HealthCheck

Source of truth (EN). Mirrored in French in `ARCHITECTURE.md` — edit both
in the same turn.

## Overview

Native macOS app (SwiftUI, macOS 15+) for personal health analytics.
Two data paths feed a local SQLite store; pure analysis engines compute
scores and statistics; SwiftUI screens render them. Everything runs
locally — the only network calls go to the Withings API when the user
connects their account.

**Founding constraint:** macOS has no HealthKit access. The framework
links (SDK marks it available since macOS 13) but
`HKHealthStore.isHealthDataAvailable()` returns `false` — verified
empirically up to macOS 27 beta. Apple Watch/iPhone data can only come
from the manual Health-app zip export.

## Data flow

```
Apple Health zip ──► ZipExtractor ──► HealthExportParser (SAX) ─┐
                          │                                     │
                          └──► RouteStore (GPX files)           ▼
                                                     ┌─────────────────┐
Withings cloud ──► WithingsClient (OAuth2) ─────────►│   HealthStore   │
                                                     │  (SQLite/GRDB)  │
                                                     └────────┬────────┘
                                                              │ reads via
                                                              ▼ SourcePriorityResolver
                                             ┌────────────────────────────┐
                                             │  Analysis engines (pure)   │
                                             │  scores · zones · Pearson  │
                                             └────────────┬───────────────┘
                                                          ▼
                                             ViewModels (@MainActor)
                                                          ▼
                                             SwiftUI views (9 sections)
```

## Storage

SQLite via GRDB, chosen over SwiftData/Core Data after measuring the
real export (844 MB, 1.8M `<Record>` elements): bulk insert at that
scale is a risk on a managed store. Batched transactions (5000 rows/tx).

Three tables, all with a **synthetic primary key** = SHA256 of
(type, source, device, dates, value, unit) because Apple provides no
stable record ID. Combined with `INSERT OR IGNORE`, every import and
every Withings sync is idempotent — verified at real scale (re-import
of 1.79M records inserts 0).

| Table | Contents | Notes |
|---|---|---|
| `health_record` | numeric samples (`type`, `value`, `unit`, dates, source) | index on `(type, startDate)` — mandatory, screens query by type+range over 2.2M rows |
| `sleep_record` | categorical sleep segments (`value` = phase string) | nights grouped by calendar day shifted −12 h |
| `workout` | sessions (activity type, duration+unit, distance, energy, `routeFileName`) | GPX files stored separately by `RouteStore` |

Date bounds are exclusive on the upper end (`startDate >= ? AND
startDate < ?`) so a midnight sample never counts twice.

**Opening at launch.** An unreadable database (corrupt, disk full,
permissions denied) no longer crashes the app: `HealthCheckApp` catches
the error, keeps a `HealthStore(unavailable:)` with no underlying
database — every method throws `HealthStoreError.unavailable` — and
`body` renders `StoreErrorView` **instead of** `ContentView`. Replacing
rather than overlaying is deliberate: import must stay unreachable, an
844 MB export must not land in a throwaway store.

Aggregates over high-frequency series (continuous heart rate: 388k
rows) are computed in SQL (`maxValue`, `averageValue`) — those series
are never loaded into memory.

## Import pipeline (Apple Health)

1. `ZipExtractor` — `/usr/bin/unzip` via `Process` into a temp dir.
2. `RouteStore.importRoutes` — copies all `.gpx` files to
   `Application Support/HealthCheck/routes/` before temp cleanup.
   File access is addressed by last path component only (no traversal).
3. `HealthExportParser` — streaming SAX (`XMLParser` on `InputStream`),
   never DOM. Unknown types/attributes are skipped, not fatal: Apple
   changes this schema across iOS versions without notice.
4. `HealthExportImporter` — buffers of 5000, flushed per batch. Flush
   errors mid-stream are captured and rethrown after parsing (a `try?`
   here once swallowed them silently — regression-tested since).

## Source priority resolution

**Source names are matched by case-insensitive substring** (2026-09-03).
A sample's `sourceName` is whatever the user named their device — "Apple
Watch de Vincent", "iPhone ☠️" — never the bare word "Watch". The original
strict equality therefore matched no real source: priority was never
applied and, on an overlap, the first sample seen won. The resolver's four
tests passed because they built their fixtures with bare "Watch" and
"iPhone".

`SourcePriorityResolver` deduplicates overlapping samples from multiple
sources (Watch > iPhone) **at read time** — raw data stays intact in
the store. Implementation is a sweep line over start-sorted records
with a window of still-open intervals. Never revert to a linear scan
of all kept records: that is O(n²) and froze the MainActor for seconds
on 28k energy samples.

Point-in-time samples (continuous HR) skip resolution entirely:
zero-length intervals never overlap, duplicates weigh 0 minutes by
construction.

## Analysis engines (pure, all tested)

All engines are `nonisolated` pure functions over value types — no
SwiftUI, no store, testable to two decimals.

| Engine | Output | Key formulas |
|---|---|---|
| `HealthScoreEngine` | readiness 0-100 | weights sleep .35 / RHR .30 / HRV .25 / activity .10, renormalized over available components; baselines = 30-day means, min 5 samples |
| `SleepScoreEngine` | night score 0-100 + `NightSummary` | duration 50 pts (target 8 h), deep 20 (≥15 %), REM 20 (≥20 %), continuity 10; duration-only fallback when no phases |
| `StrainEngine` | `DayStrain` (Z1-Z5 minutes + score) | zones at 50-90 % of max HR observed over 2 y (clamped 140-210); weights 1/2/4/7/10; gap between samples capped at 5 min; 600 load pts = 100 |
| `InsightsEngine` | French sentences | rule-based: RHR ±3 %, sleep <7 h (guard: ≥3 tracked nights), steps ±20 % at equal elapsed period, VO₂ +1, weight ±1 kg/30 d |
| `BodyCompositionEngine` | `BodySnapshot` series + `WeightSankey` | fat mass = weight × share; snapshots joined on weigh-in days; sankey level 2 omits an incoherent remainder (measures from different days) |
| `WorkoutStatsEngine` | weekly volumes + labels | duration normalized by unit (min/s/h); 20 activity types mapped to French, prefix-stripping fallback |
| `CorrelationEngine` | Pearson r + paired points | refuses <10 pairs and zero variance; day-D x paired with day-D+lag y (sleep night labeled D affects D+1 morning metrics) |
| `GPXParser` | `[RoutePoint]` | SAX, `trkpt` lat/lon only, MapKit-free |

## Training planner

Three pure engines under `HealthCheck/Analysis/` turn a race goal into
a week-by-week plan, track what was actually run against it, and watch
training load for problems. `TrainingViewModel`
(`HealthCheck/ViewModels/TrainingViewModel.swift`) is the only thing
that composes them — it recomputes `goal`/`plan`/`progress`/
`assessment` from scratch on every `load()`, nothing is persisted, so
the screen can never diverge from what a fresh call to the same three
engines would produce for the same inputs.

- **`TrainingPlanner`** builds a deterministic `TrainingPlan` from a
  `RaceGoal`, the running history, and `hrMax`. The starting weekly
  volume is the greater of the chronic load, the acute load, and a
  10 km floor; it ramps geometrically — ×1.15/week while that starting
  weekly volume is below the goal distance, ×1.10/week once at or
  above it —
  capped at 1.5× the goal distance, peaks two weeks before the race,
  then tapers ×0.75 and ×0.5 into race week. Each week's target splits
  into a long run (60 % share, grown at most 2.5 km/week off the
  longest run in the last 14 days), a hilly session (25 % share, climb
  ramped from 100 m toward `min(300, goal.elevationGainM × 0.75)`),
  base endurance filling the remainder, and an optional easy add-on.
- **`SessionMatcher`** reconciles executed runs against a
  `PlannedWeek`: distance-defined sessions are matched by size
  (largest run against largest target first), duration-defined
  sessions (leg-opener, optional easy) take whatever run is left over,
  a session counts done at 70 % of its target distance, and unmatched
  runs surface separately as `offPlan`. Recomputing this on every load
  is what lets a freshly synced run flip a session to "done" with no
  manual action.
- **`TrainingLoadMonitor`** watches acute (7-day) vs. chronic (28-day,
  4-week-average) volume and turns it into `LoadAlert`s, in one of two
  regimes (below).

**The session's motive lives in the engine, not the view.** Each
`PlannedSession` carries a `rationale` distinct from `note`: `note` is
the instruction (how to run it), `rationale` is why it exists — and it
depends on both the session kind *and* the week's role, since a long
run in a peak week and one in a taper week are not justified the same
way. Only `TrainingPlanner` knows both, so it is the only layer that
can produce the text. For the same reason, `TrainingPlan` exposes the
`anchorBaseKm` and `rampFactor` it already computed at anchoring, plus
a computed `longestPlannedRunKm`, so the training screen can explain
itself — what the plan ramps from, by how much, and how far its
longest run falls short of race distance — without recomputing
anything the engine already knows.

**One chronic-load definition, shared.** `TrainingPlanner.chronicWeeklyKm`
and `TrainingPlanner.acuteKm` are the single definitions of "chronic"
and "acute" load in the codebase — `TrainingLoadMonitor` calls them
directly rather than keeping its own reading. If the two ever
disagreed, the monitor could warn about a ratio the planner itself
just built the week's target around; sharing the definition is what
makes plan-relative alerting (below) actually consistent with the plan
on screen.

**Plan-relative alerting, and why raw ACWR must stay silent against a
ramp.** With no active goal, `TrainingLoadMonitor` falls back to the
classic acute:chronic ratio (ACWR) — above 1.3 warns "you're
progressing too fast," below 0.8 suggests doing more. But
`TrainingPlanner`'s ramp is capped by construction (×1.10–1.15/week);
a week that exactly matches the plan's own prescribed increase can
still show a raw ACWR above 1.3, especially early in a comeback where
the geometric ramp is steepest relative to a low baseline. Firing
"you're progressing too fast" next to a plan card that itself just
prescribed that increase would be self-contradictory. So whenever the
current week is present in `plan.weeks` and carries targets (`role !=
.currentWeekClosing`), `assess` compares realized volume to *that
week's target* instead of the raw ratio — over target by 25 % warns,
under target by 50 % with ≤2 days left in the week notes it won't be
caught up, and a low readiness score suggests swapping a still-pending
long run or hilly session for an easy one. The raw-ratio fallback is gated on
the **absence of a plan** (`plan == nil`), not on the outcome of the
week lookup. That distinction is anything but academic:
`TrainingPlanner` marks the current week `currentWeekClosing` as soon
as fewer than three days remain in it, so a guard keyed on the week
would have brought "you're progressing too fast" back every Saturday
and Sunday, beside a plan being followed exactly — the very
contradiction this design removes. When a plan exists but the current
week carries no targets, `assess` still publishes acute load, chronic
load and the ratio for display, but raises no alert: there is no target
to compare against, and the raw ratio is precisely the number that must
not drive an alert while a plan is active.

**Anchored at creation, not recomputed from today.** The week sequence
is derived from `goal.createdAt` — the §5.2 start-week rule is applied
once, at creation — and a week's target volume is folded forward rather
than re-derived. A past or current week ramps from the load measured
**strictly before its own Monday**, capped against the previous week's
target; a **future** week is pure projection from the previous target
and reads no load at all. Recomputing either quantity from `today`
looked harmless and broke three things at once: the current week's
target chased the volume already run (so the plan moved daily with no
user action), the horizon counted down until every plan fell into the
`<= 2` maintenance branch two weeks out (destroying the taper), and —
worst — the overshoot alert became arithmetically unreachable, because
a target that grows to match what was run can never be exceeded by
25%. A runner doing twice the prescribed volume got no warning at all.
The `min(measured, previousTarget)` cap is the no-catch-up rule: a week
run short re-bases the following weeks downward, a week overshot never
raises them. It has no floor, so a single missed week can drag the whole
remaining arc down — a 78% collapse measured on the golden fixture. The
decision is to keep that re-basing and **surface** it rather than add a
floor that would detach the plan from reality: `TrainingLoadMonitor`
raises a warning as soon as the current week's target falls below
`collapseFactor` (0.6) of the previous plan week's, both being ramp weeks
(a taper drops by design). The message names both targets and the way
out — recreating the goal re-anchors week 0 on
`max(measured load, 10 km)` (design spec §5.2bis).

**Climb is prescribed, never verified.** Every `PlannedSession` carries
a `targetClimbM`, ramped toward `goal.elevationGainM` the same way
distance is ramped — but no part of the import, companion sync, or
`Workout` model captures elevation gain anywhere in the pipeline
(design spec §6.1). `SessionMatcher` matches and marks sessions "done"
on distance alone; verifying a climb target would need GPX-derived
elevation data that nothing in this codebase extracts, so the climb
figure on a hilly session is guidance for the runner to read, not
something the app can check.

## Withings integration

Fills the gap HealthKit cannot: muscle mass, hydration, bone mass,
visceral fat have **no HealthKit type** — Withings keeps them in its
cloud and only syncs weight/fat %/lean/BMI to Apple Health.

- **OAuth2**: browser authorization on `account.withings.com`,
  callback captured by an ephemeral `NWListener` on
  `localhost:8723` (the registered redirect URI), code exchanged at
  `wbsapi.withings.net/v2/oauth2`. State parameter verified.
- **Tokens**: stored in `Application Support/HealthCheck/`
  (`withings.json` credentials, `withings-tokens.json`, chmod 600,
  outside the repo and the bundle). The refresh token is single-use:
  rewritten after every refresh.
- **Sync**: paginated `getmeas` (meastypes 1, 5, 6, 76, 77, 88, 170).
  Values scale as `value × 10^unit`; fat ratio is divided by 100 to
  match the export's fraction convention. Types with a HealthKit
  equivalent map onto the same identifiers so existing screens see
  them; the four others use custom `Withings*` type strings.
- **Auto-sync**: on launch if connected and last sync >12 h
  (`shouldAutoSync`, pure and tested).
- App sandbox entitlements: `network.client` + `network.server`
  (loopback listener).

## Companion sync (Mac receiver)

Peer-to-peer path for a future iOS companion app (tracked separately)
to push HealthKit data straight to the Mac, without the manual zip
export. This delivers the Mac-side receiver only — no iOS client yet.

- **Listener**: `SyncServer` wraps an ephemeral `NWListener` (`.tcp`,
  system-assigned port) advertised via Bonjour as `_healthcheck._tcp`.
  Started off the main actor (`Task.detached`) from `ContentView`'s
  `.task` — the first bind can trigger the local-network permission
  prompt, and `start()` blocks up to 2 s waiting for the `.ready`
  state; the main actor must never wait on that. `stop()` exists but
  is never called from the app — a listener-teardown race makes
  stop-paths unsafe until synchronized (tracked follow-up).
- **Endpoints**: minimal hand-rolled HTTP/1.1 parsing (`SyncHTTPRequest`
  / `SyncHTTPResponse`, `Connection: close`), routed by the pure
  `CompanionRouter.handle`:
  - `POST /pair` — redeems a pairing code, returns `{"token": …}`.
  - `POST /batch` — Bearer-authenticated, ingests an `ExchangeBatch`
    (records/sleep/workouts), returns `{"inserted": N}`.
  - `GET /status` — Bearer-authenticated health check (app name +
    version).
- **Pairing**: `PairingManager` opens a 6-digit-code window (120 s,
  5 attempts). On redeem it mints a 32-byte hex token, persisted by
  `CompanionTokenStore` (`companion-token.json` in Application
  Support, chmod 600) — same posture as the Withings tokens.
- **Idempotent ingestion**: `CompanionImporter.ingest` reuses the
  existing store insert paths (`insertRecords`/`insertSleepRecords`/
  `insertWorkouts`) — idempotent via the same synthetic keys +
  `INSERT OR IGNORE` as the zip pipeline. Workout GPX routes are
  written before the workout row, named deterministically
  (`companion_<ISO8601>_<activityType>.gpx`); `routeFileName` is
  stored self-healingly whenever route points are non-empty even if
  the GPX write fails — a re-delivered batch heals the missing file
  under the same name on retry.
- **Shared protocol**: `HealthCheckShared/ExchangeModels.swift` is
  compiled into both apps as a shared source group (no framework) —
  one definition of the DTOs, endpoints, and Bonjour service type, no
  drift possible between the two sides.
- **Refresh**: `CompanionViewModel.syncGeneration` increments on every
  successful insert; `ContentView`'s `onChange(of: … syncGeneration)`
  reloads the sections the companion feeds (activity, sleep, wellness,
  workouts, correlations, trends) — not body, which stays Withings
  territory. Mirrors the existing Withings handler exactly, including
  its hardcoded `.sixMonths` trends period (a known, accepted flaw,
  tracked in `TODOS.md` to be fixed for both at once).
- App sandbox: already covered by the `network.server` entitlement
  added for the Withings OAuth loopback listener — no change needed.

## Companion app (iOS)

The `HealthCheckCompanion` target (iOS 17+) is the client that talks
to the Mac receiver above — HealthKit on the phone, no manual export.

- **Mapper**: `HKMapper` converts `HKQuantitySample`/`HKCategorySample`/
  `HKWorkout` to the shared exchange DTOs using pinned units read off
  the live Mac database (spec §4, e.g. km for distance, mL/min·kg for
  VO₂ max) — the Mac ingests them with zero conversion.
- **Ack-gated anchors**: `SyncEngine` reads one `TypeDelta` per type via
  `DeltaReading` (`HealthKitReaderLive`, backed by
  `HKAnchoredObjectQuery`), pushes it in ≤ `batchLimit` batches, and
  only calls `AnchorStore.save` after every batch of that delta has
  been acked — at-least-once delivery; the Mac's idempotent ingestion
  absorbs any re-delivery after a mid-delta failure. A 401 sets
  `needsPairing` and stops the loop — no point retrying without a
  valid token.
- **Home screen shared down to the aggregates** (2026-09-02):
  `PeriodSummaryEngine` (window totals, today, week-to-date against the same
  elapsed portion of last week) and `InsightInputsBuilder` (the inputs to
  `InsightsEngine`, three-night floor included) are extracted out of
  `DashboardViewModel` into `HealthCheckShared/Analysis/`. The Mac calls them
  from `loadToday`/`loadThisWeek`/`loadWellness`, the iPhone from
  `CompanionAdvisorViewModel`'s detached pass — which therefore keeps its
  off-`MainActor` computation, its generation counter and its
  `storeUnavailable` state while showing the same numbers.
- **Shared analysis view models** (2026-09-02): the seven analysis view
  models (`Dashboard`, `Activity`, `Sleep`, `Trends`, `Correlations`,
  `Training`, `Workouts`) live in `HealthCheckShared/ViewModels/` and are
  compiled by both targets. They only depend on `HealthStore`,
  `SourcePriorityResolver` and `RouteStore`, all already shared. The ones
  that cannot follow stay Mac-only: `BodyViewModel` (Withings API),
  `ImportViewModel` (zip export), `WithingsViewModel`, `CompanionViewModel`
  (pairing server).
- **Two anchor sets, one per consumer** (2026-09-01): `anchors`
  (directory `anchors`) governs the Mac push and advances only on ack;
  `anchors-local` governs ingestion into the iPhone's own database and
  advances as soon as the insert succeeds, waiting on nothing from the
  Mac. Each pass therefore reads every type twice. Sharing them had two
  effects: the iPhone's autonomy depended on pairing, and — worse — the
  local database, added on 2026-08-28, long after the first syncs,
  could never receive the history those syncs had already consumed. A
  blank local anchor restarts from the 180-day initial window
  (`HealthKitReaderLive.initialWindowDays`), which backfills that
  history once and for all.
- **Bonjour discovery**: `BonjourEndpointProvider` browses
  `_healthcheck._tcp`, then resolves the endpoint by opening an
  ephemeral TCP connection and reading `host`/`port` off its ready
  path — formatted immediately into a URL-safe host
  (`BonjourEndpointProvider.urlHost(for:)` brackets IPv6 addresses and
  percent-encodes a link-local `%iface` scope). The Mac's listener
  port is itself ephemeral and changes on every Mac app launch, so
  `MacClient` caches the resolved endpoint for its entire lifetime (one
  instance persists for as long as the app runs) instead of
  re-discovering on every HTTP request. If a request fails on an
  address SERVED FROM CACHE (a stale port after the Mac restarted
  between two syncs), `MacClient` invalidates the cache and retries
  once with a fresh address before propagating `.unreachable`; a
  failure on an already-fresh resolution (the Mac is genuinely
  unreachable) does not trigger a second attempt. Discovery therefore
  happens once per sync attempt in the common case, twice if the port
  changed since the last sync.
- **Keychain token**: `KeychainTokenStore` holds the Bearer token
  (`mac-token` account) in the iOS Keychain. A `401`/`needsPairing`
  response clears it and flips the view model back to unpaired —
  re-pairing is the only recovery.
- **Background delivery**: `BackgroundSync` registers one
  `HKObserverQuery` per type plus `enableBackgroundDelivery` —
  `.immediate` for daily metrics (sleep, resting HR, HRV, VO₂ max),
  `.hourly` for dense streams (steps, distance, active energy,
  exercise minutes, heart rate). Delivery is opportunistic — iOS
  guarantees no schedule — so the manual "Synchroniser" button in
  `CompanionRootView` stays the reliable fallback.
- **Normalised dedup key**: the two ingestion paths describe the same
  measurement differently — the zip export timestamps to the second
  only, rounds the value and carries the real `device`, whereas
  `HKMapper` emits `device: nil` with `HKQuantity`'s full precision.
  `DedupKey` (`HealthCheckShared/Models/DedupKey.swift`) neutralises
  all three gaps across the three stored models: dates truncated to
  the second, values at four decimals (the export's precision),
  `device` excluded from the key — it is device metadata, not the
  measurement's identity. `creationDate` is not part of it either.
  Previously the key diverged on those three fields and `INSERT OR
  IGNORE` never merged the two rows. This architecture claimed
  `SourcePriorityResolver` absorbed the overlap at READ time: that
  only holds for interval samples that actually overlap (steps,
  energy, exercise time), all read through `resolver.resolve`.
  Instantaneous samples — heart rate, resting heart rate, HRV, VO2max
  — have `startDate == endDate`, therefore never overlap, and nothing
  merged them: 31,409 duplicate rows measured on the real database,
  biasing every average over those types and making the Mac diverge
  from the iPhone on the Home and Training screens.
  `HealthStore.migrateDedupKeys` carries the one-time migration
  (`PRAGMA user_version = 1`) that recomputes the `id`s and merges
  what is already stored, keeping the most informative row (GPX route
  first for a workout, then the millisecond timestamp). It is not an
  optional cleanup: without it, the first zip-export import after the
  key change would recognise no existing row and duplicate the entire
  database.
- **Sim-vs-device test split**: the 64 companion XCTest cases (mapper,
  persistence, sync engine, Mac client stub, Bonjour endpoint
  formatting, concurrent-wake coalescing, shared protocol, view model,
  advisor view model) run fully on the iPhone 17 simulator. Real Bonjour
  discovery over the local network and background-delivery wake
  timing cannot be exercised there (no local-network peers, no true
  background wake) and are validated manually on a physical iPhone —
  see [docs/companion-setup.md](docs/companion-setup.md) and the
  device-validation checklist it documents.
- **UI**: `CompanionRootView` is a five-tab `TabView` (2026-09-02, SP1 of
  the analysis-screen port) — Accueil, Activité, Sommeil, Entraînement,
  Corps. Activité and Sommeil now show the same indicators as the Mac
  (today's strain by heart-rate zone plus a 14-day histogram; last night by
  phase, 14 nights and averages), computed by the shared `ActivityViewModel`
  and `SleepViewModel`. Entraînement (2026-09-02, SP3) shows training load,
  the acute-to-chronic ratio, and VO2max computed locally by the shared
  `TrainingViewModel`, followed by the training plan held in the cache the
  Mac fills. Two sources in one screen, each in its place: the `race_goal`
  table is empty on the iPhone — race goals are created on the Mac — and
  `TrainingViewModel` handles that case explicitly, still producing the
  load assessment; that is the "between races" mode, and an iOS guard
  covers it (`TrainingViewModelIOSTests`). The cached plan lived in the
  sync screen until SP3: it moved here, because pairing is configuration
  and the plan is daily content. That tab leads to the Séances sub-screen
  (`CompanionWorkoutsView`): weekly volume stacked by activity over twelve
  weeks, then recent workouts with their figures — each shown only when it
  exists, never a manufactured zero — and, when the workout carries one, its
  GPS route (`CompanionRouteMapView`, the iOS counterpart of `RouteMapView`,
  same shared `GPXParser`). The GPX files come from `LocalStore`'s
  `RouteStore`, the one `CompanionImporter` fills while reading HealthKit —
  never the default `RouteStore()`, which points elsewhere and would find no
  file. Corps still shows a waiting screen
  Body (`CompanionBodyView`, 2026-09-03, SP5) shows the latest weigh-in with
  **its date spelled out**, body-fat share and mass, lean mass, the 30-day and
  1-year deltas, and a weight curve over the chosen period. The date is not
  decoration: the Withings → Health sync has been down since 18 June 2026, so
  the screen routinely shows a weigh-in several weeks old, and passing it off
  as today's value would be the real defect. No Sankey, no body composition —
  muscle, water, bone and visceral fat only travel through the Withings API,
  which the iPhone never calls; on that target the four `WithingsMeasureType`
  series are therefore always empty, `weightSankey` is `nil`, and an iOS guard
  checks it rather than leaving it to be discovered.

  **Weight is read, never pushed.** `HKMapper` now knows `BodyMass`,
  `BodyFatPercentage` and `LeanBodyMass`, so they enter `readTypes` and iOS
  re-prompts for authorisation. But `SyncEngine` carries **two** lists:
  `typeIdentifiers`, consumed by both passes, and `localOnlyTypes`, consumed
  by local ingestion only. The Mac already holds these measurements through
  the Withings API under different source identifiers, and since a weigh-in
  has zero duration `SourcePriorityResolver` does not deduplicate it
  (follow-up M2): pushing them would create genuine duplicates. `syncAll()`
  therefore ingests those types locally **before** its push loop — otherwise
  "Envoyer au Mac" would silently skip weight — and the guard
  (`SyncEngineTests.test_syncAll_ingestsLocalOnlyTypesLocallyAndPushesNoneOfThem`)
  observes what reaches the pusher, never the composition of the lists, which
  would be true by construction. Two details worth writing down: body fat is
  stored as a **fraction** (0.25, not 25), matching the Apple Health export and
  the Withings API, and the unit label (`kg`, `%`) is part of `DedupKey` —
  diverging from it would recreate the duplicates removed on 2026-09-03.

  **Measurement depth now reaches the screen.** A readiness component's "today"
  value is the mean of the samples known at that instant: on 2026-09-02 the
  same day read 57.0 seen with one HRV sample and 95.4 seen with nine.
  `TrendPoint.sampleCount`, filled by `DailyAggregator`, travels through
  `WellnessOrchestrator.split` — which now returns the `TrendPoint` rather than
  its value alone — into `ScoreComponent.sampleCount`, displayed by both apps.
  On **averages** only: `DailyAggregator.totals` leaves it nil, because on a
  total (energy) the sample count says nothing about the value's reliability —
  506 one day and 94 the next are two equally complete totals.
  The computation is unchanged: this is an information defect, not a formula
  one, and a refuse-to-score threshold would be arbitrary where a displayed
  count is not.

  **The readiness score now states what it could not measure.** A missing
  component does not penalise the score: `HealthScoreEngine.readiness` drops its
  weight from the basket and renormalises. With nothing shown, a score missing
  sleep (0.35, the heaviest weight) read "Excellente forme" at 97/100 — observed
  on real data on 2026-09-03. `ReadinessScore` therefore carries `missing`
  (component, nominal weight, plain-language reason) and `ScoreComponent`
  carries `share`, the real proportion after redistribution; both apps display
  them, and `HealthScoreEngine.formulaExplanation` — written against the very
  weight table it quotes, so it cannot drift from it — gives the formula in
  both. The Companion previously showed the number alone where the Mac already
  broke the components down, which is what made a gap between the two apps
  impossible to explain from the iPhone.

  An immediate consequence, fixed straight away: the Companion's Home screen
  now reads weight too. `CompanionAdvisorViewModel.defaultCompute` repeats the
  30-day window, the daily aggregation and the `WeightEngine` calls of
  `DashboardViewModel.load()`, and passes the rate alert on to
  `DailyAdviceEngine`. Without it the two Home screens would have given
  different advice on the same data — the very divergence this sub-project was
  meant to remove, reintroduced by construction.

  Two further sub-screens hang off Home (2026-09-03, SP4): Trends
  (`CompanionTrendsView`) — four curves, resting heart rate, weight, VO2max
  and sleep, each doubled by its 7-day moving average — and Correlations
  (`CompanionCorrelationsView`), the same five questions as on the Mac with
  their r, their French reading and their scatter plot. Sub-screens, not
  tabs: five is the limit past which iOS stacks the rest behind a "More"
  menu. Two measures make Trends honest about what the iPhone actually
  holds, and either without the other would fall short: the selector stops
  at 6 months (`TrendPeriod.companionCases`), because HealthKit is only
  read over `HealthKitReaderLive.initialWindowDays` (180 days) and a
  "1 year" curve would start mid-axis, indistinguishable from a gap; **and**
  the screen states the date of the earliest measurement
  (`TrendsViewModel.earliestMeasurement`) whenever history is shorter than
  the requested period — a recent HealthKit account has only weeks of depth
  even over 6 months. "6 months" is the accepted boundary case: expressed in
  calendar months it reaches up to 184 days, four beyond the window, a
  missing head measured in days rather than months. Correlations has nothing
  to bound: `CorrelationsViewModel.windowDays` is already 180, exactly the
  HealthKit window. `MetricStyle` moved up into `HealthCheckShared/Views/` so
  each metric keeps the same colour on both targets.
  Pairing and pushing to the Mac, once a tab of their own, now
  sit behind a Réglages button presented as a sheet: they are configuration,
  not a daily destination. Accueil
  (`CompanionAdvisorView`) shows readiness, daily advice, and VO2max
  trend computed locally by `CompanionAdvisorViewModel`, independent of
  Mac pairing; it refreshes on first appearance, on any manual sync, when
  returning to the foreground (`scenePhase`), and after the local
  ingestion pass `CompanionApp` runs at launch
  (`SyncEngine.ingestLocalData()` — no request to the Mac at all, so
  neither Bonjour discovery nor a network timeout is on that path). The computation
  itself (windows, readiness score, VO2max trend, training load) is a
  pure function shared with the macOS Home screen —
  `HealthCheckShared/Analysis/WellnessOrchestrator.swift`, called by
  both `CompanionAdvisorViewModel.refresh()` and
  `DashboardViewModel.loadWellness()` — so the two targets never
  silently diverge; only weight and activity insights stay Mac-only.
  Unlike the macOS view models, `refresh()` is `async` and runs its
  GRDB reads off the `MainActor` (`Task.detached`): on the iPhone they
  share the database with the HealthKit import and can wait seconds on
  its write lock. Only applying the result comes back on the
  `MainActor`, and a generation counter drops a result that a newer
  `refresh()` has superseded.
  Réglages (`CompanionSyncView`) carries the
  pairing section (6-digit code entry) while unpaired, then the sync
  section (last-sync date, report summary, "Envoyer au Mac" button) and
  unpairing once paired — and nothing else since SP3.
  `CompanionViewModel` remains the sole state holder for pairing and for
  the cached plan alike, fully protocol-injected (`Syncing`/`Pairing`) so
  it tests without HealthKit or the network; that is what made moving the
  plan safe, its tests covering the view model rather than the screen that
  renders it.

## UI structure

`NavigationSplitView` with 9 sections (Accueil, Sommeil, Effort,
Séances, Entraînement, Corps, Corrélations, Tendances, Données). One
ViewModel per section, all `@MainActor`, injected in `HealthCheckApp`.

**Load-once policy**: every ViewModel exposes `hasLoaded`; views load
on first visit only. Refresh happens exclusively through three
`onChange` triggers in `ContentView`: import completion, Withings
`syncGeneration`, and companion `syncGeneration`. A new ViewModel must
follow this pattern.

**Chart rules**: never anchor an `AreaMark` at 0 for
low-relative-amplitude quantities (body weight) — use a floor at
min − 8 % of amplitude plus `includesZero: false`. The Sankey diagram
is custom-drawn (bezier ribbons, node bars, width ∝ kg) — Swift Charts
has none.

**Language.** Two distinct mechanisms, not to be conflated:

- `CFBundleDevelopmentRegion: fr` (a literal in `project.yml`, not
  `$(DEVELOPMENT_LANGUAGE)`) drives AppKit's **system menus** — the
  SwiftUI environment cannot reach them.
- `.environment(\.locale, Locale(identifier: "fr_FR"))` on the `Scene`
  drives everything SwiftUI formats, **Swift Charts axes included**:
  without it the axes read "Jun/Jul/Aug" inside a French interface.

The per-call `Locale(identifier: "fr_FR")` arguments on some
`formatted()` sites are now redundant — kept, but unnecessary for new
call sites.

## Testing

Mac: 169 XCTest cases, engine-first: score formulas checked to 0.01,
resolver semantics, dedup idempotence through a real `:memory:` store,
Withings mapping against fixture JSON, OAuth callback parsing, GPX
parsing, path-traversal refusal, delta anchoring on last weigh-in,
companion sync (pairing window/attempts, token persistence, HTTP
parsing, router status codes, idempotent batch ingestion, GPX
self-healing), training planner/matcher/monitor/view model (golden
plan volumes, session matching, plan-relative vs. raw-ACWR alerting,
history-window coverage). UI is verified visually (Swift Charts is
invisible to accessibility tooling); training screen views stay thin
and untested like every other screen, only the view model is covered.

iOS (`HealthCheckCompanion`): 64 XCTest cases — HealthKit mapping
against pinned units, anchor/keychain persistence, sync engine
batching and ack-gated anchor advance, Mac client HTTP stub (endpoint
caching/invalidation/retry, authenticated request without a token),
`BonjourEndpointProvider` IPv4/IPv6/`.name` URL-host formatting,
concurrent-wake coalescing (`SyncCoalescer`), shared protocol
round-trip, the companion view model (pairing, full/partial/failed
sync, error states), and the advisor view model
(`CompanionAdvisorViewModel` — readiness/daily advice/VO2max trend
computed from the local store, unavailable store, no data yet, and
strict weight isolation even when local weight data exists). See the
sim-vs-device split above — Bonjour discovery and background delivery
are device-only.

`xcodegen generate` is mandatory after adding/removing files — a stale
pbxproj produces confusing "cannot find in scope" errors or empty test
runs.

## Release

`Scripts/release.sh`: Release build unsigned → `ditto
--norsrc --noextattr --noacl` staging (xattrs break `codesign`) →
Developer ID signature with Hardened Runtime (timestamp server retried
×5) → DMG (UDZO, /Applications alias) in `release/` → `notarytool
submit --wait` (keychain profile `AppliMacVincentGithub`) → staple →
`spctl` verification. v1.0.0 shipped this way (status Accepted).

## Decision log

| Decision | Why |
|---|---|
| Manual zip import stays the primary path; Mac companion receiver + iOS companion app both shipped, device validation pending | informal personal use; both sides (listener/pairing/ingestion on the Mac, HealthKit read + sync UI on iOS) are code-complete and unit-tested, but the peer-to-peer path (Bonjour on a real network, background delivery) has not yet been exercised on a physical iPhone |
| SQLite/GRDB over SwiftData | 1.8M-row bulk inserts measured on the real export |
| Read-time source resolution | raw data preserved for future analyses |
| Sleep as its own categorical table | value is a phase string, not a number |
| Withings API over CSV export | live freshness + the four HealthKit-less metrics + no manual step |
| Water outside the Sankey tree | total body water is contained in muscle/organs; adding it as a sibling compartment would double-count |
| ECG (`export_cda.xml`) excluded | clinical CDA format, outside the four analysis axes |
| Training plan/progress/assessment recomputed on every `load()`, nothing persisted | the screen can never diverge from what a fresh call to `TrainingPlanner`/`SessionMatcher`/`TrainingLoadMonitor` would produce for the same history |
| One definition of a week: `TrainingPlanner.monday`, independent of `firstWeekday` | `dateInterval(of: .weekOfYear,)` follows the machine's region, so outside a Monday-first locale the same Sunday run fell into two different weeks while the app says "this week" in both places |
| `durationMinutes` returns `Double?` rather than assuming minutes | an unrecognised unit fed an invented distance into the plan's anchor base; never derive a number from an input the app cannot interpret |
| Every workout distance goes through `WorkoutStatsEngine.distanceKilometres` | the export mixes units — 1,303 sessions in km, 26 swims **in metres**; reading `totalDistance` raw would show a 1,500 m swim as "1,500 km". Latent until the first re-import: the only distances already in the database came from companion sync, which `HKMapper` converts to km |
| Plan anchored at `goal.createdAt`, targets folded forward | a quantity recomputed from `today` makes the plan move daily, collapses the taper, and renders the overshoot alert unreachable; the cost is that recreating a goal restarts the arc |
| Climb targets prescribed but never verified | no elevation data exists anywhere in the pipeline (import, companion sync, or the `Workout` model) to check them against |
