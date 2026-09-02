# Companion SP2b — Accueil enrichi (résumés de période et insights)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** l'Accueil de l'iPhone affiche, en plus de ses trois cartes
actuelles, les résumés du jour et de la semaine et les insights — les mêmes
que l'Accueil du Mac, calculés par le même code.

**Architecture:** deux extractions hors de `DashboardViewModel`, dans
`HealthCheckShared/Analysis/`, sur le modèle de `WellnessOrchestrator` : les
agrégats de période (`PeriodSummaryEngine`) et la construction des entrées
d'insights (`InsightInputsBuilder`). `DashboardViewModel` délègue et ne change
pas de comportement — ses 279 tests macOS en sont la garde.
`CompanionAdvisorViewModel` appelle ensuite les mêmes fonctions **dans sa
passe détachée**, ce qui lui conserve tout ce qui a été construit le
2026-09-02 : calcul hors `MainActor`, compteur de génération, état
`storeUnavailable`.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-companion-full-analysis-design.md`

**Pourquoi ce plan existe séparément.** Le §5 de la spec rangeait ce travail
dans le SP2. Basculer simplement l'Accueil sur `DashboardViewModel` aurait
coûté l'asynchronisme et la gestion du store indisponible — le
`DashboardViewModel` est synchrone et lève. L'extraction est le seul chemin
qui donne les mêmes chiffres des deux côtés sans rien perdre.

## Global Constraints

- Interface et messages utilisateur en **français**, accents complets.
  Identifiants, commits et fichiers de doc en **anglais**.
- Toute garde doit avoir été **vue échouer** contre le défaut qu'elle
  surveille.
- `now` et `calendar` toujours injectés ; jamais de `Date()` dans un test.
- `HealthStore.records(type:from:to:)` borne à `startDate < to` : poser les
  mesures « du jour » avant `now`.
- Les tests macOS de `DashboardViewModel` appellent `loadToday()`,
  `loadThisWeek()` et `loadWellness()` séparément : **ces trois méthodes
  doivent survivre** aux extractions, en simples enveloppes.
- Après ajout de fichier : `xcodegen generate`.
- Référence avant de commencer : **79 tests iOS**, **279 tests macOS**.

---

### Task 1: Extraire PeriodSummaryEngine

**Files:**
- Create: `HealthCheckShared/Analysis/PeriodSummaryEngine.swift`
- Modify: `HealthCheckShared/ViewModels/DashboardViewModel.swift`
- Create: `CompanionTests/PeriodSummaryEngineTests.swift`

**Interfaces:**
- Consumes: `HealthStore`, `SourcePriorityResolver`.
- Produces: `PeriodSummary` (déplacé depuis `DashboardViewModel.swift`) et
  `PeriodSummaryEngine.summary(store:resolver:from:to:) throws -> PeriodSummary`,
  `PeriodSummaryEngine.today(store:resolver:calendar:now:) throws -> PeriodSummary`,
  `PeriodSummaryEngine.weekToDate(store:resolver:calendar:now:) throws -> (thisWeek: PeriodSummary, lastWeek: PeriodSummary?)`.

- [ ] **Step 1: Écrire le moteur**

`HealthCheckShared/Analysis/PeriodSummaryEngine.swift` :

```swift
import Foundation

struct PeriodSummary {
    let steps: Double
    let distanceKm: Double
    let activeEnergyKcal: Double
    let exerciseMinutes: Double
    let restingHeartRate: Double?
}

/// Agrégats d'une fenêtre de temps : les quatre totaux d'activité et la
/// dernière FC repos connue. Extrait de `DashboardViewModel` pour que
/// l'Accueil de l'iPhone produise exactement les mêmes chiffres que celui du
/// Mac, plutôt que de redécrire les mêmes sommes.
enum PeriodSummaryEngine {
    static func summary(store: HealthStore, resolver: SourcePriorityResolver,
                        from: Date, to: Date) throws -> PeriodSummary {
        PeriodSummary(
            steps: try sum("HKQuantityTypeIdentifierStepCount", store, resolver, from, to),
            distanceKm: try sum("HKQuantityTypeIdentifierDistanceWalkingRunning", store, resolver, from, to),
            activeEnergyKcal: try sum("HKQuantityTypeIdentifierActiveEnergyBurned", store, resolver, from, to),
            exerciseMinutes: try sum("HKQuantityTypeIdentifierAppleExerciseTime", store, resolver, from, to),
            restingHeartRate: try resolver
                .resolve(store.records(type: "HKQuantityTypeIdentifierRestingHeartRate", from: from, to: to))
                .sorted(by: { $0.startDate > $1.startDate })
                .first?.value
        )
    }

    /// La journée en cours, de son début à son lendemain.
    static func today(store: HealthStore, resolver: SourcePriorityResolver,
                      calendar: Calendar, now: Date) throws -> PeriodSummary {
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        return try summary(store: store, resolver: resolver, from: startOfDay, to: endOfDay)
    }

    /// La semaine en cours, et la précédente **à portion écoulée égale** :
    /// mercredi 15 h se compare au mercredi 15 h de la semaine passée, pas à
    /// sa semaine complète.
    static func weekToDate(store: HealthStore, resolver: SourcePriorityResolver,
                           calendar: Calendar, now: Date) throws -> (thisWeek: PeriodSummary, lastWeek: PeriodSummary?) {
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)!
        let thisWeek = try summary(store: store, resolver: resolver, from: interval.start, to: interval.end)

        guard let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start) else {
            return (thisWeek, nil)
        }
        let elapsed = now.timeIntervalSince(interval.start)
        let lastWeek = try summary(store: store, resolver: resolver,
                                   from: lastWeekStart, to: lastWeekStart.addingTimeInterval(elapsed))
        return (thisWeek, lastWeek)
    }

    private static func sum(_ type: String, _ store: HealthStore, _ resolver: SourcePriorityResolver,
                            _ from: Date, _ to: Date) throws -> Double {
        resolver.resolve(try store.records(type: type, from: from, to: to)).reduce(0) { $0 + $1.value }
    }
}
```

- [ ] **Step 2: Faire déléguer DashboardViewModel**

Dans `HealthCheckShared/ViewModels/DashboardViewModel.swift` : supprimer la
déclaration de `struct PeriodSummary` (elle vit maintenant dans le moteur),
ainsi que les méthodes privées `summary(from:to:)` et `sum(type:from:to:)`, et
réécrire les deux enveloppes — qui doivent survivre, les tests macOS les
appellent directement :

```swift
    func loadToday() throws {
        today = try PeriodSummaryEngine.today(store: store, resolver: resolver, calendar: calendar, now: now())
    }

    func loadThisWeek() throws {
        let week = try PeriodSummaryEngine.weekToDate(store: store, resolver: resolver,
                                                      calendar: calendar, now: now())
        thisWeek = week.thisWeek
        lastWeek = week.lastWeek
    }
```

- [ ] **Step 3: Vérifier que le Mac n'a rien perdu**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Executed [0-9]+ tests, with"
```

Attendu : `Executed 279 tests, with 0 failures`. Les tests de
`loadToday`/`loadThisWeek` sont la garde de cette extraction : ils décrivent
la somme après résolution de source et la comparaison à portion écoulée
égale, sans savoir où le calcul vit.

- [ ] **Step 4: Écrire la garde iOS du moteur**

`CompanionTests/PeriodSummaryEngineTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Le moteur doit être appelable depuis l'iPhone — c'est tout l'objet de
/// l'extraction — et donner les mêmes chiffres que sur le Mac.
@MainActor
final class PeriodSummaryEngineTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func record(_ type: String, _ value: Double, at date: Date, source: String = "Watch") -> HealthRecord {
        HealthRecord(type: type, sourceName: source, device: nil, unit: nil, value: value,
                     startDate: date, endDate: date.addingTimeInterval(60), creationDate: date)
    }

    func test_today_sumsActivityAndKeepsTheLatestRestingHeartRate() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let morning = calendar.startOfDay(for: now).addingTimeInterval(8 * 3600)
        try store.insertRecords([
            record("HKQuantityTypeIdentifierStepCount", 4000, at: morning),
            record("HKQuantityTypeIdentifierStepCount", 2500, at: morning.addingTimeInterval(3600)),
            record("HKQuantityTypeIdentifierDistanceWalkingRunning", 3.2, at: morning),
            record("HKQuantityTypeIdentifierActiveEnergyBurned", 300, at: morning),
            record("HKQuantityTypeIdentifierAppleExerciseTime", 25, at: morning),
            record("HKQuantityTypeIdentifierRestingHeartRate", 58, at: morning),
            record("HKQuantityTypeIdentifierRestingHeartRate", 55, at: morning.addingTimeInterval(7200))
        ])

        let summary = try PeriodSummaryEngine.today(store: store, resolver: resolver,
                                                    calendar: calendar, now: now)

        XCTAssertEqual(summary.steps, 6500)
        XCTAssertEqual(summary.distanceKm, 3.2, accuracy: 0.001)
        XCTAssertEqual(summary.activeEnergyKcal, 300)
        XCTAssertEqual(summary.exerciseMinutes, 25)
        XCTAssertEqual(summary.restingHeartRate, 55, "la dernière mesure du jour, pas la première")
    }

    func test_weekToDate_comparesToTheSameElapsedPortionOfLastWeek() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)!
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start)!
        let elapsed = now.timeIntervalSince(interval.start)

        try store.insertRecords([
            // Cette semaine, tôt : compté.
            record("HKQuantityTypeIdentifierStepCount", 5000, at: interval.start.addingTimeInterval(3600)),
            // La semaine passée, dans la portion écoulée : compté.
            record("HKQuantityTypeIdentifierStepCount", 3000, at: lastWeekStart.addingTimeInterval(3600)),
            // La semaine passée, APRÈS la portion écoulée : ignoré.
            record("HKQuantityTypeIdentifierStepCount", 9000, at: lastWeekStart.addingTimeInterval(elapsed + 3600))
        ])

        let week = try PeriodSummaryEngine.weekToDate(store: store, resolver: resolver,
                                                      calendar: calendar, now: now)

        XCTAssertEqual(week.thisWeek.steps, 5000)
        XCTAssertEqual(try XCTUnwrap(week.lastWeek).steps, 3000,
                       "la comparaison s'arrête à la portion de semaine déjà écoulée")
    }
}
```

- [ ] **Step 5: Lancer la suite iOS**

```bash
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 81 tests, with 0 failures`.

- [ ] **Step 6: Falsifier**

Deux mutations dans `PeriodSummaryEngine`, restaurées entre chaque :

1. Dans `summary`, remplacer `.sorted(by: { $0.startDate > $1.startDate })` par
   `.sorted(by: { $0.startDate < $1.startDate })` : le premier test tombe sur
   la FC repos (58 au lieu de 55).
2. Dans `weekToDate`, remplacer
   `lastWeekStart.addingTimeInterval(elapsed)` par `interval.start` (semaine
   passée complète) : le second test tombe (12 000 au lieu de 3 000).

Chaque mutation ne doit faire échouer que le test visé — et, pour la seconde,
aussi le test macOS `test_loadThisWeek_comparesToSameElapsedPortionOfPreviousWeek`,
ce qui est la preuve que les deux plateformes partagent bien le même calcul.

- [ ] **Step 7: Commit**

```bash
git add HealthCheckShared CompanionTests
git commit -m "refactor: extract PeriodSummaryEngine so the iPhone home screen can reuse it

DashboardViewModel keeps loadToday/loadThisWeek as thin wrappers - the macOS
tests call them directly and are the guard for this extraction being
behaviour-free. 279/279 macOS, 81/81 iOS."
```

---

### Task 2: Extraire la construction des entrées d'insights

**Files:**
- Create: `HealthCheckShared/Analysis/InsightInputsBuilder.swift`
- Modify: `HealthCheckShared/ViewModels/DashboardViewModel.swift`
- Modify: `CompanionTests/PeriodSummaryEngineTests.swift` (ajout)

**Interfaces:**
- Consumes: `WellnessOrchestrator.Result`, `PeriodSummary`, `InsightInputs`.
- Produces: `InsightInputsBuilder.build(wellness:thisWeek:lastWeek:weightDelta30d:calendar:today:) -> InsightInputs`.

- [ ] **Step 1: Écrire le constructeur**

`HealthCheckShared/Analysis/InsightInputsBuilder.swift` :

```swift
import Foundation

/// Assemble les entrées d'`InsightsEngine` à partir de ce que
/// `WellnessOrchestrator` a déjà agrégé et des résumés de période. Extrait de
/// `DashboardViewModel` pour que l'Accueil de l'iPhone produise les mêmes
/// observations — et surtout applique les mêmes garde-fous, comme le minimum
/// de trois nuits sans lequel une sieste isolée déclencherait une « dette de
/// sommeil ».
enum InsightInputsBuilder {
    static let minimumTrackedNights = 3

    static func build(wellness: WellnessOrchestrator.Result,
                      thisWeek: PeriodSummary?,
                      lastWeek: PeriodSummary?,
                      weightDelta30d: Double?,
                      calendar: Calendar,
                      today: Date) -> InsightInputs {
        var inputs = InsightInputs()
        guard let d7 = calendar.date(byAdding: .day, value: -7, to: today) else { return inputs }

        inputs.restingHRMean7 = mean(wellness.hrDaily.filter { $0.date >= d7 }.map(\.value))
        inputs.restingHRMean30 = mean(wellness.hrDaily.map(\.value))
        let recentNights = wellness.sleepNights.filter { $0.date >= d7 }
        inputs.sleepHoursMean7 = recentNights.count >= minimumTrackedNights
            ? mean(recentNights.map(\.value))
            : nil
        inputs.stepsThisWeek = thisWeek?.steps
        inputs.stepsLastWeek = lastWeek?.steps
        inputs.vo2Trend = wellness.vo2Trend
        inputs.weightDelta30d = weightDelta30d
        return inputs
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
```

- [ ] **Step 2: Faire déléguer DashboardViewModel**

Dans `loadWellness()`, remplacer le bloc qui construit `inputs` (de
`var inputs = InsightInputs()` jusqu'à `inputs.vo2Trend = wellness.vo2Trend`
inclus, en gardant la lecture du poids qui suit) par :

```swift
        let weightDaily = try dailyAverages(type: "HKQuantityTypeIdentifierBodyMass", from: d30, to: end)
        var weightDelta30d: Double?
        if let first = weightDaily.first?.value, let last = weightDaily.last?.value {
            weightDelta30d = last - first
        }
        let inputs = InsightInputsBuilder.build(wellness: wellness, thisWeek: thisWeek, lastWeek: lastWeek,
                                                weightDelta30d: weightDelta30d, calendar: calendar, today: end)
```

La méthode privée `mean(_:)` de `DashboardViewModel` devient inutilisée :
la supprimer. `d7` aussi, s'il ne sert plus qu'à ce bloc.

- [ ] **Step 3: Vérifier le Mac**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Executed [0-9]+ tests, with"
```

Attendu : `Executed 279 tests, with 0 failures`.

- [ ] **Step 4: Écrire la garde du minimum de nuits**

Ajouter dans `CompanionTests/PeriodSummaryEngineTests.swift` :

```swift
    func test_insightInputs_underThreeTrackedNights_leavesTheSleepMeanNil() throws {
        let calendar = Calendar.current
        let now = fixedNow
        let wellness = WellnessOrchestrator.Result(
            readiness: nil, vo2Trend: nil,
            loadAssessment: LoadAssessment(acuteKm: 0, chronicWeeklyKm: 0, acwr: nil, alerts: []),
            vo2MaxAlert: nil,
            hrDaily: [],
            sleepNights: [TrendPoint(date: calendar.date(byAdding: .day, value: -1, to: now)!, value: 7.5),
                          TrendPoint(date: calendar.date(byAdding: .day, value: -2, to: now)!, value: 8.0)])

        let inputs = InsightInputsBuilder.build(wellness: wellness, thisWeek: nil, lastWeek: nil,
                                                weightDelta30d: nil, calendar: calendar, today: now)

        XCTAssertNil(inputs.sleepHoursMean7,
                     "deux nuits ne suffisent pas : une sieste isolée déclencherait une dette de sommeil")
    }

    func test_insightInputs_withThreeTrackedNights_computesTheSleepMean() throws {
        let calendar = Calendar.current
        let now = fixedNow
        let nights = (1...3).map {
            TrendPoint(date: calendar.date(byAdding: .day, value: -$0, to: now)!, value: 8.0)
        }
        let wellness = WellnessOrchestrator.Result(
            readiness: nil, vo2Trend: nil,
            loadAssessment: LoadAssessment(acuteKm: 0, chronicWeeklyKm: 0, acwr: nil, alerts: []),
            vo2MaxAlert: nil, hrDaily: [], sleepNights: nights)

        let inputs = InsightInputsBuilder.build(wellness: wellness, thisWeek: nil, lastWeek: nil,
                                                weightDelta30d: nil, calendar: calendar, today: now)

        XCTAssertEqual(try XCTUnwrap(inputs.sleepHoursMean7), 8.0, accuracy: 0.001)
    }
```

`TrendPoint` est bien `(date: Date, value: Double)` — vérifié dans
`HealthCheckShared/Models/TrendPoint.swift`.

- [ ] **Step 5: Lancer, falsifier, commiter**

```bash
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 83 tests, with 0 failures`. Puis mutation : remplacer
`minimumTrackedNights = 3` par `= 1` — le premier des deux tests doit tomber.
Restaurer, revérifier, puis :

```bash
git add HealthCheckShared CompanionTests
git commit -m "refactor: extract InsightInputsBuilder with its three-night floor"
```

---

### Task 3: Accueil enrichi sur l'iPhone

**Files:**
- Modify: `Companion/CompanionAdvisorViewModel.swift`
- Modify: `Companion/CompanionAdvisorView.swift`
- Modify: `CompanionTests/CompanionAdvisorViewModelTests.swift`

**Interfaces:**
- Consumes: `PeriodSummaryEngine` (Task 1), `InsightInputsBuilder` (Task 2),
  `InsightsEngine.generate(from:)`.
- Produces: `CompanionAdvisorViewModel.today`, `.thisWeek`, `.lastWeek`,
  `.insights`.

- [ ] **Step 1: Écrire la garde**

Ajouter dans `CompanionTests/CompanionAdvisorViewModelTests.swift` :

```swift
    /// L'Accueil de l'iPhone doit produire les mêmes agrégats que celui du
    /// Mac, et les produire **dans la passe détachée** : `refresh()` reste
    /// asynchrone, rien ne doit être recalculé sur le `MainActor`.
    func test_refresh_alsoPublishesTodaysSummaryAndInsights() async throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = Calendar.current
            .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
            .addingTimeInterval(20 * 3600)
        let morning = calendar.startOfDay(for: now).addingTimeInterval(8 * 3600)
        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 7200, start: morning),
            record(type: "HKQuantityTypeIdentifierActiveEnergyBurned", sourceName: "Watch", value: 350, start: morning)
        ])

        let viewModel = CompanionAdvisorViewModel(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertEqual(viewModel.today?.steps, 7200)
        XCTAssertEqual(viewModel.today?.activeEnergyKcal, 350)
        XCTAssertNotNil(viewModel.thisWeek)
    }
```

- [ ] **Step 2: Lancer et constater l'échec**

Attendu : échec de compilation, `value of type 'CompanionAdvisorViewModel'
has no member 'today'`.

- [ ] **Step 3: Étendre le view model**

Dans `Companion/CompanionAdvisorViewModel.swift`, ajouter les publications :

```swift
    @Published private(set) var today: PeriodSummary?
    @Published private(set) var thisWeek: PeriodSummary?
    @Published private(set) var lastWeek: PeriodSummary?
    @Published private(set) var insights: [Insight] = []
```

Le calcul détaché ne renvoie plus seulement un `WellnessOrchestrator.Result`
mais un instantané complet. Ajouter, dans le même fichier :

```swift
/// Ce que la passe détachée rapporte au `MainActor` : tout est calculé hors
/// du fil principal, l'application du résultat n'est qu'une affectation.
struct CompanionHomeSnapshot {
    let wellness: WellnessOrchestrator.Result
    let today: PeriodSummary
    let thisWeek: PeriodSummary
    let lastWeek: PeriodSummary?
    let insights: [Insight]
}
```

et remplacer la closure `compute` par défaut, ainsi que `apply(_:)` :

```swift
    private let compute: @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> CompanionHomeSnapshot

    init(store: HealthStore, resolver: SourcePriorityResolver,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
         compute: @escaping @Sendable (HealthStore, SourcePriorityResolver, Calendar, Date) throws -> CompanionHomeSnapshot
            = { store, resolver, calendar, today in
                let wellness = try WellnessOrchestrator.compute(store: store, resolver: resolver,
                                                                calendar: calendar, today: today)
                let week = try PeriodSummaryEngine.weekToDate(store: store, resolver: resolver,
                                                              calendar: calendar, now: today)
                let inputs = InsightInputsBuilder.build(wellness: wellness, thisWeek: week.thisWeek,
                                                        lastWeek: week.lastWeek, weightDelta30d: nil,
                                                        calendar: calendar, today: today)
                return CompanionHomeSnapshot(
                    wellness: wellness,
                    today: try PeriodSummaryEngine.today(store: store, resolver: resolver,
                                                         calendar: calendar, now: today),
                    thisWeek: week.thisWeek, lastWeek: week.lastWeek,
                    insights: InsightsEngine.generate(from: inputs))
            }) {
```

`weightDelta30d` reste `nil` jusqu'au SP5 : l'iPhone n'a pas de pesée, et
`InsightsEngine` traite l'absence comme une absence, pas comme un zéro.

`apply` devient :

```swift
    private func apply(_ snapshot: CompanionHomeSnapshot) {
        let wellness = snapshot.wellness
        readiness = wellness.readiness
        vo2Trend = wellness.vo2Trend
        vo2MaxAlert = wellness.vo2MaxAlert
        dailyAdvice = DailyAdviceEngine.advise(readiness: wellness.readiness, loadAlerts: wellness.loadAssessment.alerts,
                                               vo2MaxAlert: wellness.vo2MaxAlert, weightAlert: nil)
        today = snapshot.today
        thisWeek = snapshot.thisWeek
        lastWeek = snapshot.lastWeek
        insights = snapshot.insights
    }
```

Adapter le type du `Result` dans `refresh()` :
`Result<CompanionHomeSnapshot, Error>`, et remettre à zéro `today`,
`thisWeek`, `lastWeek` et `insights` dans la branche d'échec, comme les
autres.

Les deux gardes du 2026-09-02 (état de chargement, résultat périmé)
construisent un `WellnessOrchestrator.Result` via `wellness(readiness:)` :
les adapter pour rendre un `CompanionHomeSnapshot`, en gardant leur
sémantique — c'est le même helper à un niveau d'emballage près.

- [ ] **Step 4: Lancer la suite iOS**

Attendu : `Executed 84 tests, with 0 failures`.

- [ ] **Step 5: Afficher les deux cartes**

Dans `Companion/CompanionAdvisorView.swift`, ajouter dans le `LazyVStack`,
après `readinessCard` et avant `dailyAdviceCard` :

```swift
                        if let today = viewModel.today {
                            todayCard(today)
                        }
```

et à la fin, après `vo2Card` :

```swift
                        if !viewModel.insights.isEmpty {
                            insightsCard
                        }
```

avec :

```swift
    private func todayCard(_ summary: PeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Aujourd'hui", systemImage: "sun.max.fill")
                .font(.headline)
            Text("\(Int(summary.steps.rounded())) pas · \(summary.distanceKm.formatted(.number.precision(.fractionLength(1)))) km")
                .font(.callout)
            Text("\(Int(summary.activeEnergyKcal.rounded())) kcal actives · \(Int(summary.exerciseMinutes.rounded())) min d'exercice")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let week = viewModel.thisWeek {
                Text("Cette semaine : \(Int(week.steps.rounded())) pas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Observations", systemImage: "lightbulb.fill")
                .font(.headline)
            ForEach(Array(viewModel.insights.enumerated()), id: \.offset) { _, insight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: insight.systemImage)
                        .foregroundStyle(Self.tint(for: insight.sentiment))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(.callout.weight(.semibold))
                        Text(insight.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func tint(for sentiment: Insight.Sentiment) -> Color {
        switch sentiment {
        case .positive: return .green
        case .neutral: return .secondary
        case .warning: return .orange
        }
    }
```

La condition d'écran vide en tête de la vue teste `readiness`, `dailyAdvice`
et `vo2Trend` : y ajouter `viewModel.today == nil`, sans quoi un iPhone qui a
des pas mais pas encore de baseline afficherait « Pas encore assez de
données » alors qu'il a de quoi remplir une carte.

- [ ] **Step 6: Compiler, installer, contrôler à l'écran**

Suite iOS complète, puis installation sur l'iPhone **déverrouillé** (voir le
plan SP1 pour les trois commandes). À l'écran : Accueil montre désormais
pas/distance/kcal du jour, le cumul de la semaine et les observations, en plus
des trois cartes existantes.

- [ ] **Step 7: Documentation et commit**

`ARCHITECTURE.md` et `ARCHITECTURE_EN.md` (miroirs, édités ensemble) :
mentionner les deux extractions et l'Accueil enrichi. `CHANGES.md`,
`TODOS.md`.

```bash
git add Companion CompanionTests ARCHITECTURE.md ARCHITECTURE_EN.md
git commit -m "feat(companion): show today's activity and the insights on the home tab"
```

---

## Definition of done

- `PeriodSummaryEngine` et `InsightInputsBuilder` vivent dans
  `HealthCheckShared/Analysis/` ; `DashboardViewModel` délègue et n'a pas
  changé de comportement (279 tests macOS inchangés).
- L'Accueil de l'iPhone affiche les résumés du jour et de la semaine et les
  observations, calculés dans la passe détachée — asynchronisme, compteur de
  génération et `storeUnavailable` intacts.
- 84 tests iOS, chaque garde ajoutée vue échouer contre sa mutation.
- Contrôle à l'écran fait, documentation à jour.
