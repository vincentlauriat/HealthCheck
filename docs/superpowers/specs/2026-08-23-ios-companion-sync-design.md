# HealthCheck Companion — iOS-to-Mac HealthKit sync

**Date:** 2026-08-23
**Status:** validated in discussion, awaiting written-spec review
**Decisions taken with Vincent:** iOS companion app · direct LAN push · automatic sync with manual fallback button

## 1. Context and motivation

macOS has no HealthKit access (verified empirically up to macOS 27 beta:
the framework links but `isHealthDataAvailable()` returns `false`). All
activity, heart, sleep and workout data therefore reaches the Mac app
through a manual Apple Health zip export — minutes of manual work per
refresh, so data is stale most of the time. Withings closes the gap only
for scale metrics; it is an incomplete consumer of activity data.

The companion app removes the manual step: a small iOS app reads
HealthKit incrementally and pushes new samples to the Mac over the local
network. The zip import remains the historical-backfill path.

**Direct beneficiary:** the readiness score (`ReadinessCard`) requires
same-day resting HR and HRV — structurally invisible with manual
exports (visible only on import day). With morning pushes it becomes a
daily feature.

## 2. Goals / non-goals

**Goals**

- New samples for the metric types the Mac app consumes, arriving
  automatically several times a day, with no cloud transit.
- Reuse of the Mac's existing ingestion pipeline unchanged
  (idempotent `insertRecords`, `SourcePriorityResolver`, refresh
  mechanics).
- Pairing simple enough to do once and forget.

**Non-goals (deferred, not designed here)**

- TestFlight distribution to family members.
- TLS on the LAN channel.
- Multiple paired Macs.
- A Mac background daemon receiving while the app is closed.
- Full-history transfer through the companion (the zip already covers
  history; see §7).
- Scale metrics (weight, body fat, lean mass, BMI): Withings is the
  direct, richer source (muscle, water, bone, visceral fat). The
  companion deliberately excludes them to avoid a second weight path.

## 3. Architecture overview

```
iPhone                                        Mac
┌─────────────────────────┐                  ┌──────────────────────────┐
│ HealthKit               │                  │ HealthCheck.app          │
│   ↓ HKAnchoredObjectQuery                  │  SyncServer (NWListener) │
│ HealthKitReader         │   HTTP/JSON      │   ↓ insertRecords /      │
│   ↓ mapping → exchange  │  ───────────────►│     insertSleepRecords / │
│ SyncEngine (Bonjour,    │   LAN only       │     insertWorkouts       │
│  batches, anchors,      │                  │  HealthStore (SQLite)    │
│  retry)                 │                  │   → section refresh      │
└─────────────────────────┘                  └──────────────────────────┘
```

Delivery semantics: **at-least-once**. The iPhone advances an anchor
only after the Mac acknowledges the batch; duplicates are absorbed by
the Mac's synthetic-key idempotence (SHA256 of content +
`INSERT OR IGNORE`) — the same property that already makes zip
re-imports free.

## 4. Scope of data

Types pushed, with the exact units the Mac database already contains
(verified against the live store on 2026-08-23; the companion converts
`HKQuantity` values to these units so the Mac ingests without any
conversion):

| HealthKit type | Unit |
|---|---|
| `HKQuantityTypeIdentifierStepCount` | `count` |
| `HKQuantityTypeIdentifierDistanceWalkingRunning` | `km` |
| `HKQuantityTypeIdentifierActiveEnergyBurned` | `kcal` |
| `HKQuantityTypeIdentifierAppleExerciseTime` | `min` |
| `HKQuantityTypeIdentifierHeartRate` | `count/min` |
| `HKQuantityTypeIdentifierRestingHeartRate` | `count/min` |
| `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | `ms` |
| `HKQuantityTypeIdentifierVO2Max` | `mL/min·kg` |
| `HKCategoryTypeIdentifierSleepAnalysis` | phase strings, e.g. `HKCategoryValueSleepAnalysisAsleepDeep` (same six strings the zip produces) |
| `HKWorkoutType` | duration `min`, distance `km`, energy `kcal` |

Workout routes: `HKWorkoutRoute` locations are sent as raw points
(lat, lon, timestamp); the Mac writes them as GPX files into
`RouteStore` so the existing Séances screen displays them unmodified.

`sourceName` is `HKSource.name` **verbatim** (the zip contains the
same strings — the live DB holds `Watch`, `iPhone`, `Apple Watch de
Vincent`, …). This matters: `SourcePriorityResolver` matches
`["Watch", "iPhone"]` by strict equality, and identical source strings
keep both dedup (same synthetic key as the zip's samples) and priority
resolution working identically.

## 5. iOS app — HealthCheck Companion

Bundle id `fr.vincentlauriat.healthcheck.companion`, SwiftUI, one
screen. Personal provisioning via Xcode (paid account: one-year
profiles).

### Components

- **`HealthKitReader`** — one `HKAnchoredObjectQuery` per type from
  the table above. Anchors (`HKQueryAnchor`, NSKeyedArchiver-encoded)
  persisted per type in the app's Application Support directory.
  An anchor is persisted only after the Mac has acknowledged every
  batch of the delta that produced it.
- **Background wake-up** — `HKObserverQuery` +
  `enableBackgroundDelivery` (`.hourly` for high-frequency types,
  `.immediate` for daily ones such as sleep and resting HR). The
  dominant real-world case works in our favour: overnight sleep/HRV
  samples land in HealthKit on wake-up, iPhone on its charger, on home
  Wi-Fi — exactly when a LAN push can succeed.
- **`SyncEngine`** — discovers the Mac via Bonjour
  (`_healthcheck._tcp`), resolves its current address and port, pushes
  batches of at most 500 samples per request, retries on next wake-up
  or manual trigger if the Mac is unreachable. No queue on disk beyond
  the anchors: an unsent delta is simply re-read from HealthKit next
  time.
- **UI** — pairing state, last successful sync, per-type sample counts
  of the last push, a "Synchroniser" button, and the HealthKit
  authorization flow. French labels, mirroring the Mac app's tone
  (vouvoiement).

## 6. Mac side — SyncServer

New file group under `Import/` (same neighbourhood as
`WithingsClient`).

- **Listener** — a persistent `NWListener` on an ephemeral port (port
  0, no collision with Withings' transient `8723` listener), advertised
  over Bonjour as `_healthcheck._tcp` while the app runs. Same code
  family as the OAuth callback listener, made long-lived.
- **Endpoints** (HTTP/1.1, JSON bodies):
  - `POST /pair` `{code}` → `{token}` — only while a pairing window is
    open (see §8).
  - `POST /batch` `{records: [], sleep: [], workouts: []}` with
    `Authorization: Bearer <token>` → `{inserted: n}` (the ack). Any
    of the three arrays may be empty. Workout entries may carry
    `routePoints`; the server writes the GPX file before inserting the
    workout row (mirroring the zip pipeline's ordering).
  - `GET /status` with bearer token → `{app: "HealthCheck", version}`
    — lets the iPhone show "Mac joignable".
- **Ingestion** — straight calls into the existing `HealthStore`
  insert APIs inside the existing transaction batching. No new storage
  code.
- **Refresh** — after a batch that inserted at least one row, the
  server increments a `companionSyncGeneration` on its view model
  (MainActor-hopped); `ContentView` gets one more `onChange` mirroring
  the Withings `syncGeneration` pattern. Any new view model keeps
  following the load-once rule.
- **UI** — a "iPhone" card on the Données screen next to the Withings
  card: paired/not paired, last sync time, "Appairer…" button opening
  the pairing window and showing the 6-digit code.

## 7. Initial scope and anchors

History stays with the zip (1.8 M rows already in the store). On first
authorization the companion runs its anchored queries with a predicate
of `startDate >= now − 30 days`, then goes purely incremental. This
sidesteps the known trap that a first anchored query without predicate
returns the entire history, and the ≤30-day overlap with the last zip
import is free thanks to idempotence.

## 8. Pairing and security

- First contact: Vincent clicks "Appairer…" on the Mac's Données
  screen; the Mac opens a 2-minute pairing window and displays a
  6-digit code. The iPhone submits it via `POST /pair` and receives a
  long-lived random token (32 bytes, hex).
- Token storage: Mac side in
  `Application Support/HealthCheck/companion-token.json`, chmod 600
  (Withings-token pattern); iOS side in the Keychain.
- Every subsequent request carries `Authorization: Bearer <token>`;
  wrong or missing token → 401, no body.
- No TLS in v1, accepted deliberately: home LAN, and the channel is
  **write-only** — it cannot read anything out of the store; the worst
  an attacker with the token could do is insert bogus samples.
  Rate-limited pairing attempts (5 per window) keep the code from
  being brute-forced.
- Sandbox: the Mac app already holds `network.server`; the iOS app
  needs the HealthKit entitlement + `NSHealthShareUsageDescription`,
  and local-network usage description (`NSLocalNetworkUsageDescription`
  + Bonjour service declaration).

## 9. Error handling

| Failure | Behaviour |
|---|---|
| Mac unreachable / app closed | Push aborted, anchors untouched; full catch-up on next wake-up or manual sync. Nothing is lost — HealthKit is the queue. |
| Batch rejected (non-2xx, malformed) | Anchor for that type not advanced; retried next cycle. |
| Partial multi-batch delta | Anchor advances only after the last batch acks, so a mid-delta failure re-sends from the delta's start; duplicates are absorbed. |
| Token invalidated (Mac re-paired) | 401 → iPhone surfaces "appairage requis" state, keeps anchors. |
| Route file write fails | Workout inserted without `routeFileName`; error logged in the sync report (map simply absent, like zip workouts without GPX). |

## 10. Code structure

Same repo, XcodeGen:

- New target `HealthCheckCompanion` (iOS 17+, SwiftUI).
- New source group `HealthCheckShared` compiled into both app targets
  (a plain file group, not an embedded framework — no signing or
  embedding complexity): exchange DTOs (`ExchangeRecord`, `ExchangeSleep`,
  `ExchangeWorkout`, `ExchangeRoutePoint`), the JSON coding, and the
  protocol constants (service type, endpoint paths, batch size). One
  definition, two consumers — the two sides cannot drift.
- New test target `HealthCheckCompanionTests`.

## 11. Testing strategy

Engine-first, like the rest of the project:

- **Shared:** DTO round-trip coding; batch-splitting logic.
- **iOS (pure, no HealthKit):** quantity→unit conversion table;
  sleep-phase mapping; anchor-advance-only-after-ack state machine.
- **Mac:** request parsing (header/token/JSON) on raw strings —
  `parseCallback` precedent; pairing window + rate limiting; `/batch`
  ingestion into a `:memory:` store including idempotent re-send;
  route-points→GPX writing; `companionSyncGeneration` increment.
- **On-device only:** actual HealthKit reads, background delivery
  timing, Bonjour discovery — validated manually on Vincent's iPhone
  against the running Mac app.

## 12. Known limitations (accepted)

- iOS background delivery is opportunistic: several pushes per day,
  no guaranteed schedule — hence the manual button.
- The Mac must be running (and awake) to receive; otherwise data waits
  on the iPhone side at zero cost.
- Personal provisioning expires yearly; the app must be re-deployed
  from Xcode.
- Sync only happens when both devices share a network. Away from home,
  data accumulates and catches up on return.
