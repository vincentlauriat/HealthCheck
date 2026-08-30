# Cross-Signal Daily Advice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single, priority-ranked "Conseil du jour" card to the Accueil screen, composed entirely from verdicts three existing engines already produce — no new physiological threshold, no metric recomputation.

**Architecture:** A new pure engine `HealthCheckShared/Analysis/DailyAdviceEngine.swift` maps `ReadinessScore.label` directly onto three priority tiers (`.repos`/`.prudence`/`.opportunite`) and, only under the two non-`.opportunite` tiers, may substitute a `.warning`-severity `LoadAlert` already produced by `TrainingLoadMonitor`/`VO2MaxEngine` for the tier's generic text. `DashboardViewModel` computes those inputs (history-only `TrainingLoadMonitor.assess(plan: nil, ...)`, reusing the `VO2MaxTrend` it already computes) and publishes the result; `DashboardView` renders it below the existing readiness card.

**Tech Stack:** Swift, XCTest, XcodeGen-generated Xcode project, GRDB-backed `HealthStore`.

**Spec:** `docs/superpowers/specs/2026-08-29-cross-signal-daily-advice-design.md`

## Global Constraints

- Every engine follows the existing `Analysis/` convention: `enum` of `static func`s, no clock/calendar reads inside the engine, no independent recomputation of a metric another engine already owns.
- Any test written specifically to catch a bug must be seen to fail against that exact bug before being accepted (repo convention, `CLAUDE.md`) — for new logic, the red step of TDD (compile failure, then the correct assertion failure) satisfies this; no separate mutation step is needed beyond that red/green cycle.
- macOS test command: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- Run `xcodegen generate` after adding `HealthCheckShared/Analysis/DailyAdviceEngine.swift` (new file in an already-declared source path) before the first build that references it.
- Never touch `Companion/` or `CompanionTests/` — this sub-project is macOS-only for wiring and UI; the engine is shared but nothing wires it into the iPhone app in this plan.
- Never `git add` the generated `HealthCheck.xcodeproj` — it is gitignored (`CLAUDE.md` at the repo root: "Le projet Xcode est généré par XcodeGen... et gitignoré").
- Tier mapping is exactly `readiness.label` → tier, no new scale: `"Récupération conseillée"` → `.repos`; `"Forme correcte"` → `.prudence`; `"Bonne forme"` and `"Excellente forme"` → `.opportunite` (spec §5). An unrecognized label (a future rename of `HealthScoreEngine.label(for:)`) fails safe to `.prudence`, never to the most optimistic tier — an optimistic default would silently swallow a real `.warning` alert (decision recorded 2026-08-30, advisor review).
- Generic tier copy must add something the readiness label above it doesn't already say (an action, not a restatement) — the whole point of the card is to relate signals, and three restatements of one label in ~40 vertical pixels relates nothing (decision recorded 2026-08-30, advisor review).
- A `.warning` `LoadAlert` may replace the tier's generic text only when the tier is `.repos` or `.prudence`, never `.opportunite` (spec §5). `.info` alerts never surface in this card.
- Determinism: when both a `TrainingLoadMonitor` alert and the `VO2MaxEngine` alert are `.warning`, the `loadAlerts` one wins — fixed scan order `loadAlerts` then `vo2MaxAlert` (spec §5, §10).
- `readiness == nil` → `DailyAdviceEngine.advise(...)` returns `nil` — no invented fallback text (spec §8).
- `DashboardViewModel` calls `TrainingLoadMonitor.assess(history:, plan: nil, readiness:, today:, calendar:)` — always `plan: nil`, never the full `TrainingPlan`. `ContentView.swift` runs `dashboardViewModel.load()` before `trainingViewModel.load(readiness:)`, so no plan exists yet at this point in the load sequence; recomputing it here would duplicate `TrainingViewModel.load()`'s goal-loading, 180-day `hrMax` lookup, and `TrainingPlanner.plan(...)` call (spec §6, decision recorded 2026-08-30).
- The 28-day workout history window fetched for that `assess(...)` call is exactly what `TrainingLoadMonitor` reads internally: `acuteKm` uses the last 7 days, `chronicWeeklyKm` and `weeksWithARun` use the last 28 (`TrainingPlanner.swift:110-127`, `TrainingLoadMonitor.swift:131-139`) — no wider window is needed.
- The VO2max trend passed to `VO2MaxEngine.stagnationAlert(...)` from `DashboardViewModel` is the same `VO2MaxTrend` already computed for `InsightInputs.vo2Trend` — never a second `VO2MaxEngine.trend(...)` call. The `chronicKm` argument is `LoadAssessment.chronicWeeklyKm`, already returned by the `assess(...)` call above — never a second `TrainingPlanner.chronicWeeklyKm(...)` call.

---

### Task 1: DailyAdviceEngine (pure engine)

**Files:**
- Create: `HealthCheckShared/Analysis/DailyAdviceEngine.swift`
- Test: `HealthCheckTests/DailyAdviceEngineTests.swift`
- Modify: `docs/METHODOLOGY.md` (new section `## 14`, inserted before the current `## 14. Avertissement` at line 962, which becomes `## 15`)

**Interfaces:**
- Produces: `enum AdviceTier: Equatable { case repos, prudence, opportunite }`; `struct DailyAdvice: Equatable { let tier: AdviceTier; let message: String }`; `DailyAdviceEngine.advise(readiness: ReadinessScore?, loadAlerts: [LoadAlert], vo2MaxAlert: LoadAlert?) -> DailyAdvice?`. `ReadinessScore` (`HealthCheckShared/Analysis/HealthScoreEngine.swift`) and `LoadAlert` (`HealthCheckShared/Analysis/TrainingLoadMonitor.swift`) already exist.

- [ ] **Step 1: Write the failing tests**

Create `HealthCheckTests/DailyAdviceEngineTests.swift`:

```swift
import XCTest
@testable import HealthCheck

final class DailyAdviceEngineTests: XCTestCase {
    private func readiness(label: String) -> ReadinessScore {
        ReadinessScore(value: 0, label: label, components: [])
    }

    private func alert(_ severity: LoadAlert.Severity, _ message: String) -> LoadAlert {
        LoadAlert(severity: severity, message: message)
    }

    func test_advise_reposTierAndGenericMessageWhenNoWarningPresent() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Récupération conseillée"),
            loadAlerts: [],
            vo2MaxAlert: nil
        )
        XCTAssertEqual(advice?.tier, .repos)
        XCTAssertEqual(advice?.message, "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_advise_prudenceTierAndGenericMessageWhenOnlyInfoAlertsPresent() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "Vous pouvez en faire un peu plus.")],
            vo2MaxAlert: nil
        )
        XCTAssertEqual(advice?.tier, .prudence)
        XCTAssertEqual(advice?.message, "Restez sur des séances modérées aujourd'hui — ce n'est pas le jour pour repousser vos limites.")
    }

    func test_advise_opportuniteTierWhenLabelIsBonneForme() {
        let advice = DailyAdviceEngine.advise(readiness: readiness(label: "Bonne forme"),
                                              loadAlerts: [], vo2MaxAlert: nil)
        XCTAssertEqual(advice?.tier, .opportunite)
        XCTAssertEqual(advice?.message, "Vous êtes en forme — bon moment pour une séance clé.")
    }

    func test_advise_opportuniteTierWhenLabelIsExcellenteForme() {
        let advice = DailyAdviceEngine.advise(readiness: readiness(label: "Excellente forme"),
                                              loadAlerts: [], vo2MaxAlert: nil)
        XCTAssertEqual(advice?.tier, .opportunite)
    }

    func test_advise_warningIgnoredUnderOpportuniteTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Excellente forme"),
            loadAlerts: [alert(.warning, "Vous progressez trop vite — réduisez cette semaine.")],
            vo2MaxAlert: nil
        )
        XCTAssertEqual(advice?.tier, .opportunite)
        XCTAssertEqual(advice?.message, "Vous êtes en forme — bon moment pour une séance clé.",
                      "une alerte .warning ne doit jamais remonter sous le palier opportunité")
    }

    func test_advise_warningSubstitutedUnderReposTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Récupération conseillée"),
            loadAlerts: [alert(.warning, "Vous progressez trop vite — réduisez cette semaine.")],
            vo2MaxAlert: nil
        )
        XCTAssertEqual(advice?.message, "Vous progressez trop vite — réduisez cette semaine.")
    }

    func test_advise_determinismLoadAlertsWinOverVo2MaxAlertWhenBothWarn() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.warning, "alerte de charge")],
            vo2MaxAlert: alert(.warning, "alerte VO2max")
        )
        XCTAssertEqual(advice?.message, "alerte de charge")
    }

    func test_advise_vo2MaxAlertUsedWhenLoadAlertsHaveNoWarning() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "alerte de charge info")],
            vo2MaxAlert: alert(.warning, "alerte VO2max")
        )
        XCTAssertEqual(advice?.message, "alerte VO2max")
    }

    func test_advise_nilReadinessReturnsNil() {
        XCTAssertNil(DailyAdviceEngine.advise(readiness: nil, loadAlerts: [], vo2MaxAlert: nil))
    }

    // Un libellé inconnu (renommage futur de HealthScoreEngine.label(for:),
    // par exemple) ne doit jamais retomber silencieusement sur le palier le
    // plus optimiste — ça masquerait une vraie alerte .warning.
    func test_advise_unknownLabelFailsSafeToPrudenceTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Libellé inconnu"),
            loadAlerts: [alert(.warning, "alerte de charge")],
            vo2MaxAlert: nil
        )
        XCTAssertEqual(advice?.tier, .prudence)
        XCTAssertEqual(advice?.message, "alerte de charge",
                      "palier .prudence : la substitution d'alerte doit rester active")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DailyAdviceEngineTests`
Expected: FAIL to compile — `DailyAdviceEngine`, `DailyAdvice`, `AdviceTier` do not exist yet.

- [ ] **Step 3: Write the implementation**

Create `HealthCheckShared/Analysis/DailyAdviceEngine.swift`:

```swift
import Foundation

enum AdviceTier: Equatable {
    case repos
    case prudence
    case opportunite
}

struct DailyAdvice: Equatable {
    let tier: AdviceTier
    let message: String
}

/// Compose un conseil du jour unique à partir de verdicts déjà calculés par
/// d'autres moteurs (HealthScoreEngine, TrainingLoadMonitor, VO2MaxEngine).
/// Ne recalcule jamais rien lui-même et n'introduit aucun nouveau seuil —
/// le palier est directement le label de HealthScoreEngine.label(for:).
enum DailyAdviceEngine {
    static func advise(
        readiness: ReadinessScore?,
        loadAlerts: [LoadAlert],
        vo2MaxAlert: LoadAlert?
    ) -> DailyAdvice? {
        guard let readiness else { return nil }
        let tier = Self.tier(for: readiness.label)

        // Une alerte .warning ne peut affiner le conseil que sous REPOS ou
        // PRUDENCE — jamais sous OPPORTUNITÉ, où elle contredirait le label
        // déjà affiché. Ordre de scan fixe et déterministe : les alertes de
        // charge d'abord (dans leur ordre de production), puis celle de
        // VO2max.
        if tier != .opportunite,
           let warning = (loadAlerts + [vo2MaxAlert].compactMap { $0 })
               .first(where: { $0.severity == .warning }) {
            return DailyAdvice(tier: tier, message: warning.message)
        }

        return DailyAdvice(tier: tier, message: Self.genericMessage(for: tier))
    }

    // Couplé aux libellés exacts de HealthScoreEngine.label(for:) — si ces
    // libellés changent, ce switch doit changer avec. Un libellé inconnu
    // bascule vers .prudence (palier neutre, qui autorise toujours la
    // substitution d'alerte) plutôt que vers .opportunite : un `default`
    // optimiste masquerait silencieusement une vraie alerte .warning.
    private static func tier(for label: String) -> AdviceTier {
        switch label {
        case "Récupération conseillée": return .repos
        case "Forme correcte": return .prudence
        case "Bonne forme", "Excellente forme": return .opportunite
        default: return .prudence
        }
    }

    private static func genericMessage(for tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance."
        case .prudence: return "Restez sur des séances modérées aujourd'hui — ce n'est pas le jour pour repousser vos limites."
        case .opportunite: return "Vous êtes en forme — bon moment pour une séance clé."
        }
    }
}
```

- [ ] **Step 4: Run `xcodegen generate`, then run the tests to verify they pass**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DailyAdviceEngineTests`
Expected: PASS, all 10 tests.

- [ ] **Step 5: Document the engine in METHODOLOGY.md**

In `docs/METHODOLOGY.md`, insert a new section immediately before the current `## 14. Avertissement` (line 962), and renumber that heading to `## 15. Avertissement`:

```markdown
## 14. Conseil du jour — `DailyAdviceEngine`

**Question :** « qu'est-ce que je fais aujourd'hui, en tenant compte de tout
ce que l'app sait déjà ? » — un message unique sur l'Accueil, composé à
partir de verdicts déjà calculés par d'autres moteurs, sans introduire de
nouveau seuil.

**Entrées.** Le score de forme du jour (optionnel, §4), les alertes de
charge du jour (`TrainingLoadMonitor.assess(...).alerts`, §12, appelé
depuis l'Accueil avec `plan: nil` — voir « Ce que ça ne fait pas »
ci-dessous), et l'alerte de stagnation VO2max du jour
(`VO2MaxEngine.stagnationAlert(...)`, §11.8).

**Le palier est directement le label de `HealthScoreEngine.label(for:)`** —
aucune nouvelle échelle :

| `readiness.label` | Palier |
|---|---|
| Récupération conseillée | `.repos` |
| Forme correcte | `.prudence` |
| Bonne forme / Excellente forme | `.opportunite` |

Sans score de forme (`readiness == nil`), aucun conseil n'est produit —
`advise(...)` retourne `nil`, pas de texte de repli inventé
(`DailyAdviceEngine.swift`).

**Le texte.** Sous `.repos` ou `.prudence`, une alerte de sévérité
`.warning` (charge ou VO2max) remplace le texte générique du palier si
l'une existe — jamais sous `.opportunite`, où l'afficher contredirait
« Bonne forme »/« Excellente forme ». Ordre de scan fixe et déterministe :
les alertes de `TrainingLoadMonitor` d'abord (dans leur ordre de
production), puis celle de `VO2MaxEngine` — la première trouvée l'emporte.
Les alertes `.info` ne remontent jamais ici (déjà visibles sur
Entraînement).

**Ce que ça ne fait pas.** Le moteur ne recalcule rien : ni score de
forme, ni charge, ni tendance VO2max — il compose des verdicts déjà
produits et déjà documentés ailleurs dans ce fichier. Depuis l'Accueil,
l'appel à `TrainingLoadMonitor.assess(...)` passe systématiquement
`plan: nil` : le plan d'entraînement n'est pas encore calculé à ce point
du chargement (`DashboardViewModel.loadWellness()` s'exécute avant
`TrainingViewModel.load()`), et le recalculer dupliquerait le chargement
d'objectif et de `hrMax` déjà fait par `TrainingViewModel`. Les alertes
propres à un plan actif (dépassement, retard, effondrement) restent donc
invisibles depuis l'Accueil et ne s'affichent que sur Entraînement.

---
```

- [ ] **Step 6: Commit**

```bash
git add HealthCheckShared/Analysis/DailyAdviceEngine.swift HealthCheckTests/DailyAdviceEngineTests.swift docs/METHODOLOGY.md
git commit -m "feat: add DailyAdviceEngine composing readiness with load/VO2max alerts"
```

---

### Task 2: DashboardViewModel — publish `dailyAdvice`

**Files:**
- Modify: `HealthCheck/ViewModels/DashboardViewModel.swift`
- Test: `HealthCheckTests/DashboardViewModelTests.swift`

**Interfaces:**
- Consumes: `DailyAdviceEngine.advise(readiness:loadAlerts:vo2MaxAlert:)` (Task 1); `TrainingLoadMonitor.assess(history:plan:readiness:today:calendar:) -> LoadAssessment` (existing, unchanged); `VO2MaxEngine.stagnationAlert(trend:chronicKm:) -> LoadAlert?` (existing, unchanged); `HealthStore.workouts(from:to:) throws -> [Workout]` (existing, unchanged).
- Produces: `DashboardViewModel.dailyAdvice: DailyAdvice?` (published) — consumed by Task 3 (`DashboardView`).

- [ ] **Step 1: Write the failing test**

Add to `HealthCheckTests/DashboardViewModelTests.swift`, a new test at the end of the class, before its closing brace (currently line 169):

```swift

    @MainActor
    func test_loadWellness_dailyAdviceCombinesReadinessAndLoadWarning() throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current

        // Readiness dégradée : FC repos +10 % vs. baseline de 10 jours à
        // 60 bpm → score 40 → label "Récupération conseillée" → palier .repos.
        var records: [HealthRecord] = (1...10).map { daysAgo in
            record(
                type: "HKQuantityTypeIdentifierRestingHeartRate",
                sourceName: "Watch",
                value: 60,
                start: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600)
            )
        }
        records.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch",
                              value: 66, start: calendar.startOfDay(for: now).addingTimeInterval(3600)))
        try store.insertRecords(records)

        // Charge : chronic = (10+10+10+20)/4 = 12.5 km/semaine (>= 8.0, donc
        // "meaningful"), acute (7 derniers jours) = 20 km. ACWR = 20/12.5 =
        // 1.6 > highRatio (1.3) → alerte .warning "Vous progressez trop
        // vite — réduisez cette semaine.", branche sans-plan de
        // TrainingLoadMonitor.assess.
        func run(daysAgo: Int, km: Double) -> Workout {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                           duration: 60, durationUnit: "min",
                           totalDistance: km, totalDistanceUnit: "km",
                           totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                           startDate: start, endDate: start.addingTimeInterval(3600),
                           routeFileName: nil)
        }
        try store.insertWorkouts([
            run(daysAgo: 25, km: 10.0),
            run(daysAgo: 18, km: 10.0),
            run(daysAgo: 11, km: 10.0),
            run(daysAgo: 2, km: 20.0)
        ])

        let viewModel = DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        try viewModel.loadWellness()

        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message, "Vous progressez trop vite — réduisez cette semaine.",
                      "le message doit venir de l'alerte de charge, pas du texte générique du palier — sinon la garde ne prouve pas que le câblage passe bien loadAlerts")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DashboardViewModelTests/test_loadWellness_dailyAdviceCombinesReadinessAndLoadWarning`
Expected: FAIL to compile — `DashboardViewModel.dailyAdvice` does not exist yet.

- [ ] **Step 3: Add the property and the computation**

In `HealthCheck/ViewModels/DashboardViewModel.swift`, add the published property after `insights` (currently line 17):

```swift
    @Published private(set) var dailyAdvice: DailyAdvice?
```

In `loadWellness()`, right after `inputs.vo2Trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)` (currently line 120) and before `let weightDaily = ...` (currently line 121), insert:

```swift

        let d28 = calendar.date(byAdding: .day, value: -28, to: end)!
        let recentHistory = try store.workouts(from: d28, to: end)
        let loadAssessment = TrainingLoadMonitor.assess(history: recentHistory, plan: nil,
                                                         readiness: readiness, today: end, calendar: calendar)
        let vo2MaxAlert = VO2MaxEngine.stagnationAlert(trend: inputs.vo2Trend,
                                                        chronicKm: loadAssessment.chronicWeeklyKm)
        dailyAdvice = DailyAdviceEngine.advise(readiness: readiness, loadAlerts: loadAssessment.alerts,
                                               vo2MaxAlert: vo2MaxAlert)
```

This sits after `inputs.vo2Trend` is computed (reused here, not recomputed) and after `readiness` (computed earlier in the same method, line 103-108) — both are available at this point, and `dailyAdvice` is set before `insights = InsightsEngine.generate(from: inputs)` runs.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:HealthCheckTests/DashboardViewModelTests`
Expected: PASS, all cases including every pre-existing test in the file (none of them assert on `dailyAdvice`, so none should change).

- [ ] **Step 5: Commit**

```bash
git add HealthCheck/ViewModels/DashboardViewModel.swift HealthCheckTests/DashboardViewModelTests.swift
git commit -m "feat: publish dailyAdvice from DashboardViewModel"
```

---

### Task 3: DashboardView — "Conseil du jour" card

**Files:**
- Modify: `HealthCheck/Views/WellnessViews.swift`
- Modify: `HealthCheck/Views/DashboardView.swift`

**Interfaces:**
- Consumes: `DashboardViewModel.dailyAdvice: DailyAdvice?` (Task 2); `DailyAdvice.tier: AdviceTier`, `.message: String`; `AdviceTier` (Task 1).
- Produces: nothing consumed by a later task — this is the last task in the plan.

No new automated test: this codebase has no SwiftUI view-level test target, consistent with every other card in this file (`ReadinessCard`, `InsightCard` have no dedicated view tests either). Verification for this task is: the full test suite still passes (no view model regression), the build succeeds, and a manual look at the running app.

- [ ] **Step 1: Add `DailyAdviceCard`**

In `HealthCheck/Views/WellnessViews.swift`, add a new view after `InsightCard` (currently ending at line 127), mirroring its exact visual pattern (icon badge + title + message):

```swift

/// Carte « Conseil du jour » : message unique et priorisé, dérivé du score
/// de forme et affiné par une alerte de charge/VO2max quand compatible
/// (DailyAdviceEngine.advise). Même gabarit visuel qu'InsightCard, teinté
/// par le palier plutôt que par le sentiment.
struct DailyAdviceCard: View {
    let advice: DailyAdvice

    private var tint: Color {
        switch advice.tier {
        case .repos: return .orange
        case .prudence: return .blue
        case .opportunite: return .green
        }
    }

    private var systemImage: String {
        switch advice.tier {
        case .repos: return "exclamationmark.triangle.fill"
        case .prudence: return "info.circle.fill"
        case .opportunite: return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch advice.tier {
        case .repos: return "Repos conseillé"
        case .prudence: return "Prudence"
        case .opportunite: return "Opportunité"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(advice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}
```

- [ ] **Step 2: Render the card below the readiness card**

In `HealthCheck/Views/DashboardView.swift`, the readiness block currently ends at line 21 (`}` closing the `if let readiness = viewModel.readiness` block), immediately followed by the `insights` block starting at line 23. Insert between them, still inside the outer `VStack(alignment: .leading, spacing: 28)`:

```swift

                if let dailyAdvice = viewModel.dailyAdvice {
                    DailyAdviceCard(advice: dailyAdvice)
                }
```

- [ ] **Step 3: Regenerate the project and run the full macOS suite**

Run: `xcodegen generate`
Run: `xcodebuild test -scheme HealthCheck -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
Expected: PASS, full suite, 0 failures — this task adds no failing test of its own, so this step both confirms the build succeeds (a `View` file's compile errors would fail the whole target build before any test runs) and that nothing upstream regressed.

- [ ] **Step 4: Commit**

```bash
git add HealthCheck/Views/WellnessViews.swift HealthCheck/Views/DashboardView.swift
git commit -m "feat: render the Conseil du jour card on the Accueil screen"
```

---

## After the plan

All three tasks land `feat(...)` commits building toward the spec's goal: a single, deterministic, readiness-derived daily advice card that never contradicts the label already shown next to it, sourced entirely from verdicts three existing engines already produce. Manual verification recommended once the plan is done: check the Accueil screen with a real or imported dataset that has enough resting-heart-rate/sleep history to compute a readiness score, and confirm the new card's tone (color, icon, wording) matches its tier and never overrides what the readiness card above it already says.
