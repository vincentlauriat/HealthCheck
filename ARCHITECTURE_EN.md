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

## UI structure

`NavigationSplitView` with 8 sections (Accueil, Sommeil, Effort,
Séances, Corps, Corrélations, Tendances, Données). One ViewModel per
section, all `@MainActor`, injected in `HealthCheckApp`.

**Load-once policy**: every ViewModel exposes `hasLoaded`; views load
on first visit only. Refresh happens exclusively through two
`onChange` triggers in `ContentView`: import completion and Withings
`syncGeneration`. A new ViewModel must follow this pattern.

**Chart rules**: never anchor an `AreaMark` at 0 for
low-relative-amplitude quantities (body weight) — use a floor at
min − 8 % of amplitude plus `includesZero: false`. The Sankey diagram
is custom-drawn (bezier ribbons, node bars, width ∝ kg) — Swift Charts
has none.

Charts render French labels/dates via explicit `fr_FR` locale (the
process locale is not trusted).

## Testing

68 XCTest cases, engine-first: score formulas checked to 0.01,
resolver semantics, dedup idempotence through a real `:memory:` store,
Withings mapping against fixture JSON, OAuth callback parsing, GPX
parsing, path-traversal refusal, delta anchoring on last weigh-in.
UI is verified visually (Swift Charts is invisible to accessibility
tooling).

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
| Manual zip import, no iOS companion in v1 | informal personal use; `HealthDataSource` seam kept for a future CloudKit path |
| SQLite/GRDB over SwiftData | 1.8M-row bulk inserts measured on the real export |
| Read-time source resolution | raw data preserved for future analyses |
| Sleep as its own categorical table | value is a phase string, not a number |
| Withings API over CSV export | live freshness + the four HealthKit-less metrics + no manual step |
| Water outside the Sankey tree | total body water is contained in muscle/organs; adding it as a sibling compartment would double-count |
| ECG (`export_cda.xml`) excluded | clinical CDA format, outside the four analysis axes |
