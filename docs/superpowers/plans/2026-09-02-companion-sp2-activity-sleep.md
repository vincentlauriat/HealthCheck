# Companion SP2 — Écrans Activité et Sommeil

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** remplir les onglets Activité et Sommeil du Companion avec les mêmes
indicateurs que le Mac, calculés par les view models partagés au SP1.

**Architecture:** aucun calcul nouveau. `ActivityViewModel` et
`SleepViewModel` vivent déjà dans `HealthCheckShared/ViewModels/` ; ce plan
écrit leurs vues iOS et, au passage, les premiers tests qu'ils aient jamais
eus — ni l'un ni l'autre n'était couvert côté macOS. Les vues suivent le
gabarit du Companion (cartes à coins de 8, fond `systemGroupedBackground`),
pas celui du Mac.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Charts, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-companion-full-analysis-design.md`

**Écart assumé avec la spec.** Le §5 range l'enrichissement d'Accueil dans le
SP2. Il en est retiré : il exige d'extraire la construction des résumés de
période et des insights hors de `DashboardViewModel` pour que
`CompanionAdvisorViewModel` — qui, lui, est asynchrone, hors `MainActor`, avec
compteur de génération et état `storeUnavailable` — puisse les produire sans
perdre ces propriétés. C'est une extraction de la même nature que
`WellnessOrchestrator`, et elle mérite son propre plan plutôt que la fin de
celui-ci. Elle fera l'objet du plan SP2b.

## Global Constraints

- Interface et messages utilisateur en **français**, accents complets.
  Identifiants, commits et fichiers de doc en **anglais**.
- Toute garde de non-régression doit avoir été **vue échouer** contre le
  défaut qu'elle surveille avant d'être acceptée.
- `now` et `calendar` toujours injectés ; jamais de `Date()` dans un test.
- `HealthStore.records(type:from:to:)` borne à `startDate < to` : un
  échantillon posé exactement à `now` est **exclu**. Poser les mesures « du
  jour » avant `now`.
- Après ajout de fichier : `xcodegen generate`.
- Tests iOS **sans** `CODE_SIGNING_ALLOWED=NO`, simulateur `iPhone 17`.
- Référence avant de commencer : **73 tests iOS**, **279 tests macOS**.

---

### Task 1: Écran Activité

**Files:**
- Create: `CompanionTests/ActivityViewModelTests.swift`
- Create: `Companion/Views/CompanionScoreRingView.swift`
- Modify: `Companion/Views/CompanionActivityView.swift` (remplace l'écran d'attente)

**Interfaces:**
- Consumes: `ActivityViewModel(store:resolver:calendar:now:)` avec
  `today: DayStrain?`, `history: [DayStrain]`, `maxHeartRate: Double?`,
  `todayActiveEnergy: Double?`, `todayExerciseMinutes: Double?`,
  `hasLoaded: Bool`, `load() throws` ; `DayStrain` expose `day: Date`,
  `score: Double`, `zoneMinutes: [Double]` ; `StrainEngine.label(for:)`.
- Produces: `CompanionScoreRingView(score:)`, réutilisée par la Task 2 ;
  `CompanionActivityView(viewModel:)`.

- [ ] **Step 1: Écrire les tests du view model**

`CompanionTests/ActivityViewModelTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Premiers tests d'`ActivityViewModel` : il n'en avait aucun, ni côté macOS
/// ni ailleurs. Les fixtures posent leurs mesures avant `now`, parce que
/// `HealthStore.records` borne à `startDate < to`.
@MainActor
final class ActivityViewModelTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    /// Horloge fixe à 20 h locale : laisse la place pour poser des mesures
    /// dans la journée, et évite les échecs à minuit.
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func heartRate(_ value: Double, at date: Date) -> HealthRecord {
        HealthRecord(type: "HKQuantityTypeIdentifierHeartRate", sourceName: "Watch",
                     device: nil, unit: "count/min", value: value,
                     startDate: date, endDate: date, creationDate: date)
    }

    func test_load_usesTheObservedMaximumHeartRate_clampedToAPlausibleRange() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        // Un pic à 180 il y a 100 jours : dans la fenêtre de 2 ans du view model.
        try store.insertRecords([heartRate(180, at: calendar.date(byAdding: .day, value: -100, to: now)!)])

        let viewModel = ActivityViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertEqual(viewModel.maxHeartRate, 180,
                       "la FC max observée sur 2 ans sert de référence aux zones")
    }

    func test_load_withNoHeartRateAtAll_leavesEverythingEmptyWithoutThrowing() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = ActivityViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.maxHeartRate)
        XCTAssertNil(viewModel.today)
        XCTAssertTrue(viewModel.history.isEmpty)
    }

    func test_load_buildsTodayStrainAndTodaysEnergyAndExercise() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let startOfToday = calendar.startOfDay(for: now)

        var records = [heartRate(180, at: calendar.date(byAdding: .day, value: -100, to: now)!)]
        // Une heure d'effort ce matin : 13 points à 150 bpm espacés de 5 min.
        for step in 0..<13 {
            records.append(heartRate(150, at: startOfToday.addingTimeInterval(8 * 3600 + Double(step) * 300)))
        }
        records.append(HealthRecord(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                                    sourceName: "Watch", device: nil, unit: "kcal", value: 420,
                                    startDate: startOfToday.addingTimeInterval(9 * 3600),
                                    endDate: startOfToday.addingTimeInterval(9 * 3600 + 60),
                                    creationDate: nil))
        records.append(HealthRecord(type: "HKQuantityTypeIdentifierAppleExerciseTime",
                                    sourceName: "Watch", device: nil, unit: "min", value: 55,
                                    startDate: startOfToday.addingTimeInterval(9 * 3600),
                                    endDate: startOfToday.addingTimeInterval(9 * 3600 + 60),
                                    creationDate: nil))
        try store.insertRecords(records)

        let viewModel = ActivityViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        let today = try XCTUnwrap(viewModel.today)
        XCTAssertEqual(today.day, startOfToday)
        XCTAssertGreaterThan(today.score, 0, "une heure à 150 bpm doit produire un effort non nul")
        XCTAssertGreaterThan(today.zoneMinutes.reduce(0, +), 0)
        XCTAssertEqual(viewModel.todayActiveEnergy, 420)
        XCTAssertEqual(viewModel.todayExerciseMinutes, 55)
    }
}
```

- [ ] **Step 2: Lancer et constater le résultat**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 76 tests, with 0 failures`. Ces tests décrivent le
comportement existant du view model ; s'ils échouent, lire l'écart avant de
toucher au code — le view model est en production sur le Mac depuis des
semaines.

- [ ] **Step 3: Falsifier les trois gardes**

Une mutation par garde, chacune restaurée avant la suivante
(`git checkout -- HealthCheckShared/ViewModels/ActivityViewModel.swift`) :

1. Remplacer `min(max(observedMax, 140), 210)` par `observedMax` **et** poser
   dans le premier test un pic à 250 au lieu de 180 : sans le clamp la valeur
   passe à 250. (Variante plus simple : remplacer le clamp par `min(max(observedMax, 140), 175)`
   et vérifier que le premier test tombe à 175.)
2. Remplacer `today = history.last(where: { $0.day == startOfToday })` par
   `today = nil` : le troisième test échoue sur `XCTUnwrap`.
3. Remplacer `todayActiveEnergy = energy.last?.value` par `= nil` : le
   troisième test échoue sur l'assertion des 420 kcal.

Chaque mutation doit faire échouer **le test visé et lui seul**.

- [ ] **Step 4: Commit des tests**

```bash
git add CompanionTests/ActivityViewModelTests.swift
git commit -m "test: cover ActivityViewModel, which had no tests at all"
```

- [ ] **Step 5: Écrire l'anneau de score**

`Companion/Views/CompanionScoreRingView.swift` :

```swift
import SwiftUI

/// Anneau de score, équivalent iOS de `ScoreRingView` (macOS, non compilé par
/// cette cible). Trait plus fin et diamètre réduit : sur iPhone la carte est
/// deux fois plus étroite que sur le Mac.
struct CompanionScoreRingView: View {
    let score: Double

    private var tint: Color {
        switch score {
        case 70...: return .green
        case 50..<70: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(score / 100, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(score.rounded()))")
                .font(.title3.bold())
                .monospacedDigit()
        }
        .frame(width: 76, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(Int(score.rounded())) sur 100")
    }
}
```

- [ ] **Step 6: Écrire l'écran Activité**

Remplacer intégralement `Companion/Views/CompanionActivityView.swift` :

```swift
import SwiftUI
import Charts

/// Onglet « Activité » : effort du jour par zone de fréquence cardiaque et
/// historique sur 14 jours, calculés localement par `ActivityViewModel`
/// (partagé avec le Mac). Gabarit visuel du Companion, pas celui du Mac.
struct CompanionActivityView: View {
    @ObservedObject var viewModel: ActivityViewModel

    private static let zoneNames = ["Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"]
    private static let zoneColors: [Color] = [.blue, .teal, .yellow, .orange, .red]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if viewModel.today == nil && viewModel.history.isEmpty {
                    ContentUnavailableView(
                        "Pas encore d'effort mesuré",
                        systemImage: "figure.walk",
                        description: Text("Portez votre montre pendant l'effort : les zones se calculent à partir de la fréquence cardiaque.")
                    )
                    .padding(.top, 40)
                } else {
                    todayCard
                    if !viewModel.history.isEmpty {
                        historyCard
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Effort du jour", systemImage: "flame.fill")
                .font(.headline)
            if let maxHR = viewModel.maxHeartRate {
                Text("Zones basées sur votre FC max observée : \(Int(maxHR)) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 6) {
                    CompanionScoreRingView(score: viewModel.today?.score ?? 0)
                    Text(StrainEngine.label(for: viewModel.today?.score ?? 0))
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    let zones = viewModel.today?.zoneMinutes ?? [0, 0, 0, 0, 0]
                    let maxMinutes = max(zones.max() ?? 1, 1)
                    ForEach(Array(zones.enumerated().reversed()), id: \.offset) { index, minutes in
                        HStack(spacing: 8) {
                            Text(Self.zoneNames[index])
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Self.zoneColors[index])
                                .frame(width: 46, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary)
                                    Capsule()
                                        .fill(Self.zoneColors[index])
                                        .frame(width: max(geo.size.width * minutes / maxMinutes, minutes > 0 ? 4 : 0))
                                }
                            }
                            .frame(height: 7)
                            Text("\(Int(minutes.rounded())) min")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let energy = viewModel.todayActiveEnergy, let exercise = viewModel.todayExerciseMinutes {
                Text("\(Int(energy.rounded())) kcal actives · \(Int(exercise.rounded())) min d'exercice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("14 derniers jours", systemImage: "chart.bar.fill")
                .font(.headline)
            Chart(viewModel.history, id: \.day) { day in
                BarMark(x: .value("Jour", day.day, unit: .day), y: .value("Effort", day.score))
                    .foregroundStyle(Self.severityColor(day.score))
                    .cornerRadius(2)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func severityColor(_ score: Double) -> Color {
        switch score {
        case 70...: return .red
        case 40..<70: return .orange
        default: return .green
        }
    }
}
```

- [ ] **Step 7: Câbler l'onglet**

Dans `Companion/CompanionApp.swift`, construire le view model à côté des deux
autres et le passer à `CompanionRootView` :

```swift
    @StateObject private var activityViewModel: ActivityViewModel
```

initialisé dans `init()` après `advisorViewModel` :

```swift
        _activityViewModel = StateObject(wrappedValue: ActivityViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
```

et passé à la vue racine :

```swift
            CompanionRootView(viewModel: viewModel, advisorViewModel: advisorViewModel,
                              activityViewModel: activityViewModel)
```

Dans `Companion/CompanionRootView.swift`, ajouter la propriété
`@ObservedObject var activityViewModel: ActivityViewModel` et remplacer
`CompanionActivityView()` par `CompanionActivityView(viewModel: activityViewModel)`.

- [ ] **Step 8: Compiler et lancer la suite**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 76 tests, with 0 failures`.

- [ ] **Step 9: Commit**

```bash
git add Companion CompanionTests
git commit -m "feat(companion): fill the Activité tab with the shared strain view model"
```

---

### Task 2: Écran Sommeil

**Files:**
- Create: `CompanionTests/SleepViewModelTests.swift`
- Modify: `Companion/Views/CompanionSleepView.swift` (remplace l'écran d'attente)
- Modify: `Companion/CompanionApp.swift`, `Companion/CompanionRootView.swift` (câblage)

**Interfaces:**
- Consumes: `SleepViewModel(store:resolver:calendar:now:)` avec
  `nights: [NightSummary]`, `lastNight: NightSummary?`, `averageHours`,
  `averageScore`, `averageDeepShare`, `averageRemShare`, `hasLoaded`,
  `load() throws` ; `NightSummary` expose `night: Date`, `asleepHours`,
  `deepHours`, `remHours`, `coreHours`, `awakeCount: Int`, `score: Double` ;
  `CompanionScoreRingView` (Task 1).
- Produces: `CompanionSleepView(viewModel:)`.

- [ ] **Step 1: Écrire les tests du view model**

`CompanionTests/SleepViewModelTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Premiers tests de `SleepViewModel`. Le regroupement par nuit décale de
/// 12 h (`startOfDay(for: start - 12h)`), donc une nuit posée à 23 h est
/// rattachée au jour de son coucher.
@MainActor
final class SleepViewModelTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func segment(_ value: String, from: Date, hours: Double) -> SleepRecord {
        SleepRecord(type: "HKCategoryTypeIdentifierSleepAnalysis", sourceName: "Watch",
                    device: nil, value: value, startDate: from,
                    endDate: from.addingTimeInterval(hours * 3600), creationDate: from)
    }

    /// Une nuit complète : 5 h de sommeil léger, 1,5 h de profond, 1,5 h de REM.
    private func night(startingAt bedtime: Date) -> [SleepRecord] {
        [segment("HKCategoryValueSleepAnalysisAsleepCore", from: bedtime, hours: 5),
         segment("HKCategoryValueSleepAnalysisAsleepDeep", from: bedtime.addingTimeInterval(5 * 3600), hours: 1.5),
         segment("HKCategoryValueSleepAnalysisAsleepREM", from: bedtime.addingTimeInterval(6.5 * 3600), hours: 1.5)]
    }

    func test_load_summarizesTheLastNightAndItsPhases() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let lastBedtime = calendar.startOfDay(for: now).addingTimeInterval(-1 * 3600)  // 23 h hier
        _ = try store.insertSleepRecords(night(startingAt: lastBedtime))

        let viewModel = SleepViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        let last = try XCTUnwrap(viewModel.lastNight)
        XCTAssertEqual(last.asleepHours, 8, accuracy: 0.01)
        XCTAssertEqual(last.deepHours, 1.5, accuracy: 0.01)
        XCTAssertEqual(last.remHours, 1.5, accuracy: 0.01)
        XCTAssertEqual(last.coreHours, 5, accuracy: 0.01)
        XCTAssertGreaterThan(last.score, 0)
    }

    func test_load_averagesAcrossNights() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let lastBedtime = calendar.startOfDay(for: now).addingTimeInterval(-1 * 3600)
        var records = night(startingAt: lastBedtime)
        records += night(startingAt: calendar.date(byAdding: .day, value: -1, to: lastBedtime)!)
        _ = try store.insertSleepRecords(records)

        let viewModel = SleepViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertEqual(viewModel.nights.count, 2)
        XCTAssertEqual(try XCTUnwrap(viewModel.averageHours), 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(viewModel.averageDeepShare), 1.5 / 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(viewModel.averageRemShare), 1.5 / 8, accuracy: 0.01)
    }

    func test_load_withNoSleepAtAll_leavesAveragesNilWithoutThrowing() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = SleepViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.lastNight)
        XCTAssertNil(viewModel.averageHours)
        XCTAssertTrue(viewModel.nights.isEmpty)
    }
}
```

- [ ] **Step 2: Lancer et constater le résultat**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 79 tests, with 0 failures`.

- [ ] **Step 3: Falsifier les gardes**

Une mutation par garde, restaurée entre chaque
(`git checkout -- HealthCheckShared/ViewModels/SleepViewModel.swift`) :

1. Remplacer `nights = Array(all.suffix(14))` par `nights = []` : les deux
   premiers tests échouent, le troisième reste vert (il attend déjà du vide) —
   preuve qu'il ne surveille rien de plus que l'absence de crash, ce qui est
   son rôle.
2. Remplacer `averageDeepShare = ...` par `= nil` : seul le second test tombe.

- [ ] **Step 4: Commit des tests**

```bash
git add CompanionTests/SleepViewModelTests.swift
git commit -m "test: cover SleepViewModel, which had no tests at all"
```

- [ ] **Step 5: Écrire l'écran Sommeil**

Remplacer intégralement `Companion/Views/CompanionSleepView.swift` :

```swift
import SwiftUI
import Charts

/// Onglet « Sommeil » : dernière nuit détaillée par phases, historique des
/// 14 dernières nuits et moyennes, calculés localement par `SleepViewModel`
/// (partagé avec le Mac).
struct CompanionSleepView: View {
    @ObservedObject var viewModel: SleepViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let last = viewModel.lastNight {
                    lastNightCard(last)
                } else {
                    ContentUnavailableView(
                        "Aucune nuit enregistrée",
                        systemImage: "moon.zzz",
                        description: Text("Portez votre montre la nuit : les phases de sommeil viennent de Santé.")
                    )
                    .padding(.top, 40)
                }
                if !viewModel.nights.isEmpty {
                    nightsCard
                    averagesCard
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private func lastNightCard(_ night: NightSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Dernière nuit", systemImage: "moon.zzz.fill")
                .font(.headline)
            Text(night.night.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                CompanionScoreRingView(score: night.score)
                VStack(alignment: .leading, spacing: 6) {
                    phaseRow("Durée totale", hours: night.asleepHours, tint: .indigo, icon: "moon.zzz.fill")
                    phaseRow("Profond", hours: night.deepHours, tint: .indigo, icon: "moon.fill")
                    phaseRow("REM", hours: night.remHours, tint: .purple, icon: "sparkles")
                    phaseRow("Léger", hours: night.coreHours, tint: .blue, icon: "moon")
                    HStack(spacing: 8) {
                        Image(systemName: "eye.fill").font(.caption).foregroundStyle(.orange).frame(width: 18)
                        Text("Réveils").font(.caption.weight(.medium))
                        Spacer()
                        Text("\(night.awakeCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func phaseRow(_ name: String, hours: Double, tint: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint).frame(width: 18)
            Text(name).font(.caption.weight(.medium))
            Spacer()
            Text(Self.formatHours(hours)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var nightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("14 dernières nuits", systemImage: "chart.bar.fill")
                .font(.headline)
            Chart(viewModel.nights, id: \.night) { night in
                BarMark(x: .value("Nuit", night.night, unit: .day),
                        y: .value("Heures", night.asleepHours))
                    .foregroundStyle(.indigo)
                    .cornerRadius(2)
            }
            .frame(height: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var averagesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Moyennes", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
            if let hours = viewModel.averageHours {
                LabeledContent("Durée", value: Self.formatHours(hours))
            }
            if let score = viewModel.averageScore {
                LabeledContent("Score", value: "\(Int(score.rounded())) / 100")
            }
            if let deep = viewModel.averageDeepShare {
                LabeledContent("Profond", value: "\(Int((deep * 100).rounded())) %")
            }
            if let rem = viewModel.averageRemShare {
                LabeledContent("REM", value: "\(Int((rem * 100).rounded())) %")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func formatHours(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return "\(total / 60) h \(String(format: "%02d", total % 60))"
    }
}
```

- [ ] **Step 6: Câbler l'onglet**

Dans `Companion/CompanionApp.swift` :

```swift
    @StateObject private var sleepViewModel: SleepViewModel
```

initialisé dans `init()` :

```swift
        _sleepViewModel = StateObject(wrappedValue: SleepViewModel(
            store: advisorStore, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
```

passé à la vue racine :

```swift
            CompanionRootView(viewModel: viewModel, advisorViewModel: advisorViewModel,
                              activityViewModel: activityViewModel,
                              sleepViewModel: sleepViewModel)
```

Dans `Companion/CompanionRootView.swift` :

```swift
    @ObservedObject var sleepViewModel: SleepViewModel
```

et l'onglet devient :

```swift
            NavigationStack {
                CompanionSleepView(viewModel: sleepViewModel).navigationTitle("Sommeil")
            }
            .tabItem { Label("Sommeil", systemImage: "moon.zzz.fill") }
```

- [ ] **Step 7: Compiler, lancer la suite, installer**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 79 tests, with 0 failures`. Puis installation sur
l'iPhone **déverrouillé** :

```bash
xcodebuild -scheme HealthCheckCompanion -configuration Debug \
    -destination 'id=30EEDEE3-2740-529B-95CA-889A2F829410' \
    -derivedDataPath build/DeviceBuild -allowProvisioningUpdates build
xcrun devicectl device install app --device 30EEDEE3-2740-529B-95CA-889A2F829410 \
    build/DeviceBuild/Build/Products/Debug-iphoneos/HealthCheckCompanion.app
xcrun devicectl device process launch --terminate-existing \
    --device 30EEDEE3-2740-529B-95CA-889A2F829410 fr.vincentlauriat.healthcheck.companion
```

À vérifier à l'écran : l'onglet Activité montre l'effort du jour et
l'histogramme des 14 jours ; l'onglet Sommeil montre la dernière nuit, ses
phases et les moyennes. Rappel : les nuits de Vincent s'arrêtent au 25 août
dans Santé — un écran Sommeil sans dernière nuit est donc le comportement
attendu, pas un défaut.

- [ ] **Step 8: Mettre la documentation à jour puis commit**

`ARCHITECTURE.md` et `ARCHITECTURE_EN.md` (miroirs stricts, édités ensemble) :
les onglets Activité et Sommeil ne sont plus des écrans d'attente.
`CHANGES.md` : entrée datée. `TODOS.md` : cocher SP2 et noter le report de
l'enrichissement d'Accueil au SP2b.

```bash
git add Companion CompanionTests ARCHITECTURE.md ARCHITECTURE_EN.md
git commit -m "feat(companion): fill the Sommeil tab with the shared sleep view model"
```

---

## Definition of done

- Les onglets Activité et Sommeil affichent les mêmes indicateurs que le Mac,
  calculés par les view models partagés.
- 79 tests iOS (73 + 6), 279 tests macOS inchangés.
- `ActivityViewModel` et `SleepViewModel`, qui n'avaient aucun test, en ont
  désormais — et chaque garde a été vue échouer contre une mutation ciblée.
- Contrôle à l'écran fait sur l'iPhone.
- Documentation à jour dans le même tour que le code.
