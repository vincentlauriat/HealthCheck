# HealthCheck — Shared analysis foundation for an autonomous iPhone app

**Decisions taken with Vincent (2026-08-28):** iPhone app becomes autonomous
(reads HealthKit and computes locally, works without the Mac reachable) ·
v1 UI scope is Accueil + Entraînement, designed later as sub-project 4 ·
current Companion "cache the Mac's plan" WIP ships first, unchanged, as its
own increment · this is sub-project 0 of 4 (foundation, then VO2max/training
advisor, cross-cutting advice, weight advisor, then the iPhone UI).

## 1. Context and motivation

HealthCheck's entire analysis stack — `Analysis/` (11 pure engines),
`Store/HealthStore.swift` (GRDB/SQLite persistence), `Store/SourcePriorityResolver.swift`,
`Models/` (`HealthRecord`, `Workout`, `SleepRecord`, `RaceGoal`,
`TimedHealthValue`), and `Import/CompanionImporter.swift` +
`Import/GPXParser.swift` (`RouteStore`) — lives under `HealthCheck/`, compiled
only into the macOS target. `Companion` (the iOS app) is currently a thin
relay: `HealthKitReaderLive` reads HealthKit via `HKAnchoredObjectQuery` and
`SyncEngine` pushes the delta to the Mac over LAN; nothing is computed or
stored on the iPhone itself. macOS has no HealthKit access (verified
empirically), so today the Mac is the only place any of this logic runs.

None of this code is macOS-specific: every file above imports only
`Foundation` (+ `GRDB`, which supports iOS). The repository already has a
precedent for sharing code between the two targets without a separate
framework — `HealthCheckShared/`, a plain source directory compiled into
both targets, documented in `ExchangeModels.swift` as deliberate ("une seule
définition, aucune dérive possible entre les deux côtés"). This sub-project
extends that same pattern to the analysis stack, and teaches `Companion` to
run it locally, fed by its own (already-existing) HealthKit reads instead of
only relaying them.

This is the prerequisite for every other advisor sub-project: whatever new
engine logic gets written for VO2max, weight, or cross-cutting advice only
needs writing once and works on both platforms from day one.

## 2. Goals / non-goals

**Goals**

- `Analysis/`, `Store/`, `Models/`, `CompanionImporter`, `RouteStore` compile
  into both `HealthCheck` (macOS) and `HealthCheckCompanion` (iOS) targets,
  unchanged in behavior.
- `Companion` maintains its own local `HealthStore` (SQLite via GRDB),
  populated directly from HealthKit reads it already performs today.
- The very first sync after pairing (or after enabling local storage)
  captures enough history for `Analysis/` engines to produce real output
  immediately — not an empty state for weeks.
- Local insertion and the existing Mac push remain independent: neither
  blocks or is gated on the other succeeding.

**Non-goals**

- No new SwiftUI screens on iPhone — sub-project 4 designs the UI once this
  foundation exists.
- No cross-device sync of `RaceGoal` or any other user-entered data — each
  device's local store is independent. The in-flight Companion WIP (caching
  the Mac's computed plan for offline viewing) already covers the
  near-term "don't re-enter the goal twice" need and ships first, unchanged.
- No change to the existing Mac-push path's guarantees (idempotent batches,
  anchor-advances-only-after-Mac-ack, 401 stops the sync pass). Local
  insertion is purely additive.
- No new advisor features (VO2max, weight, cross-cutting advice) — those are
  sub-projects 1-3, designed against this foundation once it exists.

## 3. Architecture overview

```
                    HealthCheckShared/  (compiled into BOTH targets)
                    ├── Analysis/            (11 engines, unchanged)
                    ├── Store/               (HealthStore, SourcePriorityResolver)
                    ├── Models/              (HealthRecord, Workout, SleepRecord,
                    │                          RaceGoal, TimedHealthValue)
                    ├── Import/
                    │   ├── CompanionImporter.swift   (ExchangeBatch -> store)
                    │   └── GPXParser.swift           (RouteStore, GPX writing)
                    └── ExchangeModels.swift  (already shared)

macOS (HealthCheck target)                    iOS (HealthCheckCompanion target)
┌──────────────────────────┐                  ┌──────────────────────────────┐
│ HealthStore (Mac db)      │                  │ HealthStore (new: iPhone db)  │
│  ← zip import              │                  │  ← CompanionImporter.ingest   │
│  ← CompanionImporter       │                  │      (called locally, not    │
│      .ingest(batch)        │                  │       just over HTTP)        │
│      (via CompanionRouter, │                  │                               │
│       HTTP, unchanged)     │                  │ HealthKitReaderLive          │
│                            │                  │  → SyncEngine.syncAll()      │
│                            │                  │      ├─▶ pusher.push (Mac,   │
│                            │                  │      │    unchanged)         │
│                            │                  │      └─▶ CompanionImporter   │
│                            │                  │           .ingest (NEW: same │
│                            │                  │           local instance)    │
└──────────────────────────┘                  └──────────────────────────────┘
```

The insight this design relies on: `CompanionImporter.ingest(_:)` is already
the single conversion path from `ExchangeBatch` to stored rows (used today by
`CompanionRouter`'s HTTP batch handler on the Mac). Feeding it from
`SyncEngine` locally on the iPhone, instead of only from an HTTP request on
the Mac, needs no new conversion code — the same function processes the same
`ExchangeBatch` type either way, one call site added rather than one
reimplemented.

## 4. File migration

`git mv`, preserving history, no logic changes:

| From | To |
|---|---|
| `HealthCheck/Analysis/*.swift` (11 files) | `HealthCheckShared/Analysis/` |
| `HealthCheck/Store/HealthStore.swift` | `HealthCheckShared/Store/` |
| `HealthCheck/Store/SourcePriorityResolver.swift` | `HealthCheckShared/Store/` |
| `HealthCheck/Models/*.swift` (5 files) | `HealthCheckShared/Models/` |
| `HealthCheck/Import/CompanionImporter.swift` | `HealthCheckShared/Import/` |
| `HealthCheck/Import/GPXParser.swift` | `HealthCheckShared/Import/` |

`project.yml`: add GRDB as a dependency of the `HealthCheckCompanion` target
(currently it has none). No source-path changes needed — both targets
already list `HealthCheckShared` as a source directory. Run `xcodegen
generate` after.

Everything else in `HealthCheck/Import/` (`CompanionRouter`, `CompanionPairing`,
`SyncHTTP`, `SyncServer`, `HealthExportImporter`, `HealthExportParser`,
`WithingsClient`, `WithingsModels`, `ZipExtractor`, `TrainingPlanProvider`)
stays macOS-only — none of it is needed on the iPhone.

**Acceptance for this step in isolation:** both targets build, and every
existing `HealthCheckTests` test passes unchanged — this is a pure
relocation, and the existing macOS test suite is what proves nothing broke.

## 5. Local HealthStore on Companion

New, small wiring in `Companion/` (not shared — this is iPhone-specific
setup, mirroring how `HealthCheckApp` constructs the Mac's `HealthStore`
today):

```swift
let dbPath = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("health.sqlite").path
let localStore = try HealthStore(path: dbPath)
let localRouteStore = RouteStore()  // same default as today, iOS sandbox-scoped
let localImporter = CompanionImporter(store: localStore, routeStore: localRouteStore)
```

`HealthStore.init(path:)` already takes a plain path with no macOS-specific
assumption — this is a straight reuse, not an adaptation.

## 6. SyncEngine: local insertion alongside the Mac push

`SyncEngine` gains a `localImporter: CompanionImporter` dependency. In
`syncAll()`, right after computing `delta` for a type (before the push loop),
the same delta — reshaped into one `ExchangeBatch`, same as what gets pushed —
is ingested locally:

```swift
let batch = ExchangeBatch(records: delta.records, sleep: delta.sleep, workouts: delta.workouts)
do {
    _ = try localImporter.ingest(batch)
} catch {
    os_log(.error, "Insertion locale échouée pour %{public}@", type)
    // pas de retour anticipé : la tentative de push Mac continue quel que soit ce résultat
}
```

This runs **unconditionally**, independent of whether the Mac push that
follows succeeds, fails, or is never reachable — the entire point of
autonomy is that local storage does not depend on the Mac. The existing
anchor-advance rule is unchanged: the anchor still advances only after the
Mac push's last batch is acked. This means local insertion may reprocess
the same growing window repeatedly while the Mac stays unreachable — harmless,
since `CompanionImporter.ingest` is idempotent (`INSERT OR IGNORE` semantics,
same guarantee the zip import and the HTTP batch path already rely on).

This independence holds at the scope of the whole per-type loop in
`syncAll()`, not just within a single iteration relative to its own push
outcome: a per-type failure (including an `.unauthorized` Mac response) must
stop only that type's push and any further push attempts for the remaining
types — never the local ingestion already reached, and never the loop
itself before it reaches local ingestion for the remaining types. An
unpaired iPhone (the default state of a fresh install) still has every type
ingested locally on each sync pass, even though none of them can push.

## 7. Historical backfill on first sync

`HealthKitReaderLive.initialWindowDays` (currently `30`, chosen only because
the Mac already has full history via zip import and Companion previously only
needed to fill the recent gap) is widened to **180 days** — the longest
lookback any existing engine or provider uses today (`TrainingPlanProvider`'s
`hrMaxWindowDays`). This is a single-constant change: the same
`HKAnchoredObjectQuery`-with-bounded-first-predicate mechanism already in
`HealthKitReaderLive.delta(for:since:)` handles both the wider first sync and
the normal incremental sync afterward — no second query mechanism needed.

This widened first sync feeds both consumers identically (local insert and
Mac push both see the same 180-day initial delta) — more historical data
reaching the Mac on first pairing too, which is harmless given the Mac's
ingestion is already idempotent.

**Superseded on 2026-09-01:** the 180-day first sync only ever applied to a
*blank* anchor, so an install that had already been syncing to the Mac before
this store existed never received its own history — the local database started
at the day the feature shipped. Fixed by giving local ingestion its own anchor
set; see ARCHITECTURE §Companion.

**Accepted limitation:** a user with less than ~4-6 months of Apple Watch
history will still see engines that need longer baselines (e.g. VO2max's
120-day window, once sub-project 1 lands) report insufficient data on the
iPhone, exactly as they would on a freshly-onboarded Mac. Not addressed here.

## 8. Error handling

- **Local insertion failure** (e.g. disk write error): logged via `os_log`,
  does not block the Mac push attempt for that type, does not fail
  `syncAll()`. Not retried independently of the next natural sync pass.
- **Reversed on 2026-09-01 — see ARCHITECTURE §Companion, "two anchor sets".**
  Local ingestion now has its own anchor set (`anchors-local`), advanced on a
  successful local insert rather than on the Mac's ack. A local insertion
  failure therefore *does* leave that window to be re-read on the next pass,
  and `NoOpImporter` throws instead of returning 0 so that a store it could
  not open never advances an anchor. The paragraph below records the original
  decision and no longer describes the code.
- **~~Accepted gap:~~** if local insertion fails on a sync where the Mac push
  *succeeds*, the anchor still advances (Mac-push-gated, unchanged), so that
  specific window is not retried into the local store. This mirrors the
  existing app-wide convention of not building bespoke retry machinery for
  local write failures (none of `HealthStore`'s other callers have one
  either) rather than introducing a second, more complex anchor per
  consumer for a rare failure mode (disk errors are uncommon; network
  failures, which the existing Mac-push retry already handles, are not).
- **`HealthStore` unavailable on iPhone** (open failure): same
  `HealthStoreError.unavailable` path the Mac app already has. `Companion`
  falls back to relay-only behavior (push to Mac still attempted) — local
  storage being unavailable must not regress today's sync-to-Mac feature.

## 9. Code structure

| File | Change |
|---|---|
| `HealthCheckShared/Analysis/*.swift` (moved) | No change, relocation only. |
| `HealthCheckShared/Store/HealthStore.swift`, `SourcePriorityResolver.swift` (moved) | No change. |
| `HealthCheckShared/Models/*.swift` (moved) | No change. |
| `HealthCheckShared/Import/CompanionImporter.swift`, `GPXParser.swift` (moved) | No change. |
| `project.yml` | `HealthCheckCompanion` target gains the GRDB package dependency. |
| `Companion/LocalStore.swift` (new) | Constructs the iPhone's `HealthStore` + `RouteStore` + `CompanionImporter`, exposes them for `SyncEngine` and (later, sub-project 4) view models. |
| `Companion/Sync/SyncEngine.swift` (modify) | Gains `localImporter` dependency; `syncAll()` ingests locally, unconditionally, before the push attempt. |
| `Companion/Sync/HealthKitReaderLive.swift` (modify) | `initialWindowDays`: `30` → `180`. |

Tests mirror these under `CompanionTests/` (new) and existing `HealthCheckTests/`
(unchanged, must still pass).

## 10. Testing strategy

- `HealthCheckTests`: run as-is after the file move — zero expected changes
  in behavior or pass/fail status. This is the primary regression gate for
  this sub-project.
- `CompanionTests` (new):
  - `SyncEngine` ingests a delta locally even when the Mac push fails
    (`.unreachable`/`.serverError`) — local store receives the batch, sync
    report still reflects the push failure.
  - `SyncEngine` still advances the anchor only after Mac ack, unchanged
    from today, verified with a fake `localImporter` that always succeeds.
  - `HealthKitReaderLive`/its fake: first sync (`anchor == nil`) requests a
    180-day window, not 30.
  - Local insertion failure (fake `CompanionImporter` throwing) does not
    prevent the Mac push attempt or fail `syncAll()`.
- Per repo convention, any test written specifically to catch a bug in this
  feature must be seen to fail against a reintroduced version of that bug
  before being accepted.

## 11. Known limitations (accepted)

- Widening `initialWindowDays` to 180 for everyone means a first pairing now
  sends more historical data to the Mac than before. Accepted: harmless
  (idempotent), and simpler than maintaining two different windows for two
  consumers of the same query.
- Local insertion failures on an otherwise-successful sync are not retried
  (§8) — accepted rather than building a second anchor-tracking mechanism
  for a failure mode with no existing precedent of special handling
  elsewhere in the app.
- This sub-project does not give the iPhone app any user-visible feature by
  itself — no screen reads the new local store yet. It is deliberately inert
  until sub-project 4. Verification is therefore test-based, not a manual
  walkthrough.
- The 180-day-window test (§7) covers only the extracted pure function
  (`HealthKitReaderLive.initialSyncStart`), not the `anchor == nil` wiring in
  `HealthKitReaderLive.delta(for:since:)` that actually calls it — that path
  is untestable without live HealthKit access. Accepted: the pure function is
  the part with logic worth testing; the wiring is a one-line call verified
  by inspection.
