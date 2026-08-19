# Architecture — HealthCheck

Source of truth (EN). Mirrored in French in `ARCHITECTURE.md` — edit both
in the same turn.

## Overview

Native macOS app (SwiftUI, macOS 15 Sequoia minimum) that imports Apple
Health data exported manually from iOS and produces health/exercise
analyses. No live HealthKit access exists on macOS (not even via Mac
Catalyst) — confirmed empirically (no Health.app under
`/System/Applications` or `/Applications`). Import is the only viable
data path in v1.

## Layers

```
Zip export Santé
      │
      ▼
┌─────────────┐   HealthDataSource    ┌─────────────┐        ┌──────────────┐
│  Importer   │ ─────protocol───────► │    Store    │ ◄────► │  Dashboard   │
│ (zip+parse) │                       │  (SQLite)   │        │  (SwiftUI)   │
└─────────────┘                       └─────────────┘        └──────────────┘
```

- **Importer**: extracts the `.zip`, streams `export.xml` via SAX
  (`XMLParser`), never loads the full 844 MB+ file as DOM. Unknown
  record types/attributes are skipped, not fatal — Apple changes this
  schema across iOS versions without notice.
- **Store**: SQLite via GRDB, batched transactions (~5000 rows/tx).
  Chosen over SwiftData/Core Data after measuring the user's real export
  (844 MB, 1.8M `<Record>` elements) — bulk insert at that scale is a
  performance/reliability risk on a managed store. Synthetic primary key
  (hash of type+source+device+dates+value+unit, since Apple provides no
  stable record ID) makes re-import idempotent (`INSERT OR IGNORE`).
- **Dashboard**: SwiftUI + Swift Charts, reads through a source-priority
  resolution layer (Watch > iPhone for continuously-measured metrics) to
  avoid double-counting overlapping samples — raw data stays untouched in
  the store for future specs.

## Data volumes (measured, user export 2026-08-19)

- `export.xml`: 844 MB, 1,806,362 `<Record>`, 23,672 `<Workout>`
- `export_cda.xml` (ECG, CDA format): 482 MB — out of scope
- `workout-routes/`: 413 GPX files
- Total unzipped: ~1.5 GB

## Extension point

Import goes through a `HealthDataSource` protocol. Today implemented by
the zip file reader; a future companion iOS app + CloudKit push feed
could implement the same protocol without touching Store or UI. Not
built in v1 — deliberately deferred.

## Spec roadmap

1. Import + dedup + storage + daily dashboard (in progress)
2. Long-term trends
3. Detailed workout tracking (+ GPX routes)
4. Cross-metric health correlations
