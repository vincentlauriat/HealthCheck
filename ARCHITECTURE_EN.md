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
                                             SwiftUI views (8 sections)
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
- **Bonjour discovery**: `BonjourEndpointProvider` browses
  `_healthcheck._tcp`, then resolves the endpoint by opening an
  ephemeral TCP connection and reading `host`/`port` off its ready
  path. The Mac's listener port is itself ephemeral and changes on
  every Mac app launch, so the provider re-discovers on every sync
  attempt rather than caching an address.
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
- **`device: nil` dedup ruling**: `HKMapper` always emits `device: nil`
  on exchange records/sleep — HealthKit's per-device metadata doesn't
  map reliably onto the zip-export dedup keys. `sourceName` is kept as
  the verbatim HealthKit source name, so the companion path produces
  the exact same synthetic keys and priority resolution as zip import.
- **Sim-vs-device test split**: the 26 companion XCTest cases (mapper,
  persistence, sync engine, Mac client stub, shared protocol,
  view model) run fully on the iPhone 17 simulator. Real Bonjour
  discovery over the local network and background-delivery wake
  timing cannot be exercised there (no local-network peers, no true
  background wake) and are validated manually on a physical iPhone —
  see [docs/companion-setup.md](docs/companion-setup.md) and the
  device-validation checklist it documents.
- **UI**: a single screen, `CompanionRootView` (SwiftUI `Form`) —
  a pairing section (6-digit code entry) while unpaired, a sync
  section (last-sync date, report summary, manual button) once
  paired. `CompanionViewModel` is the sole state holder, fully
  protocol-injected (`Syncing`/`Pairing`) so it tests without HealthKit
  or the network.

## UI structure

`NavigationSplitView` with 8 sections (Accueil, Sommeil, Effort,
Séances, Corps, Corrélations, Tendances, Données). One ViewModel per
section, all `@MainActor`, injected in `HealthCheckApp`.

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

Mac: 106 XCTest cases, engine-first: score formulas checked to 0.01,
resolver semantics, dedup idempotence through a real `:memory:` store,
Withings mapping against fixture JSON, OAuth callback parsing, GPX
parsing, path-traversal refusal, delta anchoring on last weigh-in,
companion sync (pairing window/attempts, token persistence, HTTP
parsing, router status codes, idempotent batch ingestion, GPX
self-healing). UI is verified visually (Swift Charts is invisible to
accessibility tooling).

iOS (`HealthCheckCompanion`): 26 XCTest cases — HealthKit mapping
against pinned units, anchor/keychain persistence, sync engine
batching and ack-gated anchor advance, Mac client HTTP stub, shared
protocol round-trip, and the companion view model (pairing, sync,
error states). See the sim-vs-device split above — Bonjour discovery
and background delivery are device-only.

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
