# Companion SP3 — Onglet Entraînement et écran Séances

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** l'onglet Entraînement montre la charge, l'ACWR, le VO2max et le plan
d'entraînement ; un sous-écran Séances liste les sorties avec leurs traces GPS.

**Architecture:** trois sources déjà en place, aucune nouvelle règle métier.
La charge et le VO2max viennent de `TrainingViewModel` (partagé au SP1),
calculés localement. Le plan vient du cache que le Companion tient déjà depuis
le 2026-08-25 (`CompanionViewModel.trainingPlan`), simplement **déplacé** de
l'onglet Synchro vers Entraînement, où il a sa place. Les séances viennent de
`WorkoutsViewModel` et les traces du `RouteStore` local.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Charts, MapKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-companion-full-analysis-design.md`

**Le point de conception, tranché ici.** `TrainingViewModel.load()` lit la
table `race_goal`, qui est vide sur l'iPhone — les objectifs se créent sur le
Mac. Ce n'est pas un obstacle : le view model gère explicitement ce cas
(« sans objectif actif, le plan et la progression n'ont pas de sens, mais le
moniteur de charge reste pertinent ») et produit quand même `assessment` et
`vo2MaxStatus`. L'onglet combine donc deux sources : le calcul local pour la
charge et le VO2max, le cache venu du Mac pour le plan. C'est exactement la
répartition que le Companion applique déjà.

## Global Constraints

- Interface et messages utilisateur en **français**, accents complets.
  Identifiants, commits et fichiers de doc en **anglais**.
- Toute garde doit avoir été **vue échouer** contre le défaut qu'elle
  surveille. Relire le fichier muté **dans le même appel** que le commit :
  lancer la restauration ne prouve pas qu'elle a eu lieu.
- `now` et `calendar` toujours injectés ; jamais de `Date()` dans un test.
- `HealthStore.records(type:from:to:)` borne à `startDate < to`.
- Après ajout de fichier : `xcodegen generate`.
- Tests iOS **sans** `CODE_SIGNING_ALLOWED=NO`, simulateur `iPhone 17`.
- Référence avant de commencer : **84 tests iOS**, **279 tests macOS**.
- Travailler sur la branche `feat/companion-sp3-training-workouts`, jamais
  sur `main`.
- Symboles vérifiés dans le code avant d'écrire ce plan, pas supposés :
  `Workout(activityType:sourceName:duration:durationUnit:totalDistance:totalDistanceUnit:totalEnergyBurned:totalEnergyBurnedUnit:startDate:endDate:routeFileName:)`
  (pas de `creationDate`), `LoadAlert(severity:message:)`,
  `VO2MaxTrend.recentAverage`, `CompanionViewModel.isPaired`,
  `GPXParser.points(from:) -> [RoutePoint]`.

---

### Task 1: Onglet Entraînement — charge et VO2max

**Files:**
- Create: `CompanionTests/TrainingViewModelIOSTests.swift`
- Modify: `Companion/Views/CompanionTrainingView.swift` (remplace l'écran d'attente)
- Modify: `Companion/CompanionApp.swift`, `Companion/CompanionRootView.swift`

**Interfaces:**
- Consumes: `TrainingViewModel(store:calendar:now:)` avec
  `assessment: LoadAssessment?`, `vo2MaxStatus: VO2MaxStatus?`, `goal`, `plan`,
  `progress`, `hasLoaded`, `load(readiness:) throws` ; `LoadAssessment` expose
  `acuteKm`, `chronicWeeklyKm`, `acwr: Double?`, `alerts: [LoadAlert]`.
- Produces: `CompanionTrainingView(viewModel:planViewModel:)`.

- [ ] **Step 1: Écrire la garde du cas iPhone**

`CompanionTests/TrainingViewModelIOSTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Sur l'iPhone la table `race_goal` est vide — les objectifs se créent sur le
/// Mac. Le suivi de charge doit malgré tout fonctionner : c'est ce qui rend
/// l'onglet Entraînement utile hors de tout plan.
@MainActor
final class TrainingViewModelIOSTests: XCTestCase {
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func run(daysAgo: Int, km: Double, now: Date, calendar: Calendar) -> Workout {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                       duration: 45, durationUnit: "min",
                       totalDistance: km, totalDistanceUnit: "km",
                       totalEnergyBurned: 400, totalEnergyBurnedUnit: "kcal",
                       startDate: start, endDate: start.addingTimeInterval(2700),
                       routeFileName: nil)
    }

    func test_load_withNoRaceGoal_stillProducesTheLoadAssessment() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        _ = try store.insertWorkouts([
            run(daysAgo: 3, km: 10, now: now, calendar: calendar),
            run(daysAgo: 10, km: 10, now: now, calendar: calendar),
            run(daysAgo: 17, km: 10, now: now, calendar: calendar),
            run(daysAgo: 24, km: 10, now: now, calendar: calendar)
        ])

        let viewModel = TrainingViewModel(store: store, now: { now })
        try viewModel.load()

        XCTAssertNil(viewModel.goal, "aucun objectif n'est créé depuis l'iPhone")
        XCTAssertNil(viewModel.plan)
        let assessment = try XCTUnwrap(viewModel.assessment,
                                       "le suivi de charge ne doit pas dépendre d'un objectif")
        XCTAssertGreaterThan(assessment.chronicWeeklyKm, 0)
    }
}
```

Si la signature de `Workout` ou de `insertWorkouts` diffère, lire
`HealthCheckShared/Models/Workout.swift` et `HealthStore` et employer les
vraies — ne pas inventer de membres.

- [ ] **Step 2: Lancer, constater le résultat**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 85 tests, with 0 failures`.

- [ ] **Step 3: Falsifier**

Dans `TrainingViewModel.load()`, remplacer le contenu de la branche
`guard let activeGoal else { … }` par `assessment = nil` avant le `return`.
La garde doit tomber sur son `XCTUnwrap`. Restaurer avec
`git checkout -- HealthCheckShared/ViewModels/TrainingViewModel.swift`, puis
**relire le fichier** pour confirmer la restauration.

- [ ] **Step 4: Écrire la vue**

Remplacer `Companion/Views/CompanionTrainingView.swift` :

```swift
import SwiftUI

/// Onglet « Entraînement » : charge et VO2max calculés localement
/// (`TrainingViewModel`), plan d'entraînement issu du cache alimenté par le
/// Mac (`CompanionViewModel`). Les objectifs se créent sur le Mac : sans
/// objectif, la charge reste affichée, c'est le mode « suivi entre deux
/// courses ».
struct CompanionTrainingView: View {
    @ObservedObject var viewModel: TrainingViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let assessment = viewModel.assessment {
                    loadCard(assessment)
                }
                if let status = viewModel.vo2MaxStatus {
                    vo2Card(status)
                }
                if viewModel.assessment == nil && viewModel.vo2MaxStatus == nil {
                    ContentUnavailableView(
                        "Pas encore de séance enregistrée",
                        systemImage: "figure.run",
                        description: Text("Vos sorties apparaîtront ici dès qu'elles seront enregistrées dans Santé.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private func loadCard(_ assessment: LoadAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Charge d'entraînement", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
            LabeledContent("7 derniers jours",
                           value: "\(assessment.acuteKm.formatted(.number.precision(.fractionLength(1)))) km")
            LabeledContent("Moyenne hebdomadaire",
                           value: "\(assessment.chronicWeeklyKm.formatted(.number.precision(.fractionLength(1)))) km")
            if let acwr = assessment.acwr {
                LabeledContent("Rapport aigu/chronique",
                               value: acwr.formatted(.number.precision(.fractionLength(2))))
            }
            ForEach(Array(assessment.alerts.enumerated()), id: \.offset) { _, alert in
                Label(alert.message,
                      systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func vo2Card(_ status: VO2MaxStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("VO2max", systemImage: "lungs.fill")
                .font(.headline)
            if let trend = status.trend {
                Text("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg")
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) millilitres par minute et par kilo")
            }
            if let alert = status.alert {
                Label(alert.message,
                      systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
```

Si `VO2MaxStatus` n'expose pas `trend`/`alert` sous ces noms, lire
`HealthCheckShared/ViewModels/TrainingViewModel.swift` où il est déclaré.

- [ ] **Step 5: Câbler**

Dans `CompanionApp` : `@StateObject private var trainingViewModel: TrainingViewModel`,
initialisé `TrainingViewModel(store: advisorStore)`, passé à `CompanionRootView`
qui gagne `@ObservedObject var trainingViewModel: TrainingViewModel` et rend
`CompanionTrainingView(viewModel: trainingViewModel)`.

- [ ] **Step 6: Compiler, lancer la suite, commiter**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
git add Companion CompanionTests
git commit -m "feat(companion): show training load and VO2max on the Entrainement tab"
```

---

### Task 2: Déplacer le plan d'entraînement vers l'onglet Entraînement

**Files:**
- Modify: `Companion/CompanionSyncView.swift` (retrait du plan)
- Modify: `Companion/Views/CompanionTrainingView.swift` (accueil du plan)
- Modify: `Companion/CompanionRootView.swift`

**Interfaces:**
- Consumes: `CompanionViewModel.trainingPlan: TrainingPlanResponse?`,
  `.isLoadingTrainingPlan`, `.refreshTrainingPlan()`,
  `.toggleTrainingSessionCompleted(id:)`, `.isTrainingSessionCompleted(id:)`.
- Produces: `CompanionTrainingView(viewModel:planViewModel:)`.

Le plan est mis en cache depuis le 2026-08-25 et vit aujourd'hui dans
l'onglet Synchro, où il n'a rien à faire : l'appairage est une configuration,
le plan est un contenu quotidien.

- [ ] **Step 1: Déplacer les vues telles quelles**

Couper de `CompanionSyncView` et coller dans `CompanionTrainingView`, sans
rien changer à leur corps : `currentWeek`, `visibleWeeks`,
`trainingPlanContent`, `emptyPlanCard`, `warningCard`, `goalSummary`,
`weekCard`, `sessionList`, `sessionRow`, `monday(of:)`. Elles référencent
`viewModel` (le `CompanionViewModel`) : dans la vue d'accueil elles
référenceront `planViewModel`. Renommer **uniquement** ces occurrences.

`CompanionTrainingView` gagne :

```swift
    @ObservedObject var planViewModel: CompanionViewModel
```

et son `body` intercale, après les cartes de charge et de VO2max :

```swift
                planSection
```

avec :

```swift
    @ViewBuilder
    private var planSection: some View {
        if planViewModel.isPaired {
            trainingPlanContent
        }
    }
```

Le plan n'a de sens qu'appairé : c'est le Mac qui le calcule.

- [ ] **Step 2: Vérifier ce qui reste dans Synchro**

`CompanionSyncView` ne doit plus contenir que l'appairage, la carte de synchro
et le dépairage. Vérifier qu'aucune référence orpheline ne subsiste :

```bash
grep -n "trainingPlan\|weekCard\|sessionRow\|visibleWeeks" Companion/CompanionSyncView.swift
```

Attendu : aucune sortie, sauf le bouton « Plan » de `syncCard` — le
déplacer lui aussi dans `CompanionTrainingView`, en tête du plan, puisque
c'est là qu'il agit désormais.

- [ ] **Step 3: Compiler et lancer la suite**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 85 tests, with 0 failures`. Les tests de
`CompanionViewModel` (cache du plan, cases à cocher) ne bougent pas : ils
portent sur le view model, pas sur l'écran qui l'affiche — c'est ce qui rend
ce déplacement sûr.

- [ ] **Step 4: Commit**

```bash
git add Companion
git commit -m "refactor(companion): move the cached training plan to the Entrainement tab"
```

---

### Task 3: Écran Séances avec les traces GPS

**Files:**
- Create: `CompanionTests/WorkoutsViewModelTests.swift`
- Create: `Companion/Views/CompanionWorkoutsView.swift`
- Create: `Companion/Views/CompanionRouteMapView.swift`
- Modify: `Companion/Views/CompanionTrainingView.swift` (lien de navigation)
- Modify: `Companion/CompanionApp.swift`, `Companion/CompanionRootView.swift`

**Interfaces:**
- Consumes: `WorkoutsViewModel(store:routeStore:calendar:now:)` avec
  `recentWorkouts: [WorkoutItem]`, `weeklyVolumes: [WeekVolume]`,
  `thisWeekCount: Int`, `thisWeekMinutes: Double`, `thisWeekKcal: Double`,
  `hasLoaded`, `load() throws` ; `WorkoutItem` expose `label`, `startDate`,
  `minutes: Double?`, `distanceKm: Double?`, `energyKcal: Double?`,
  `averageHeartRate: Double?`, `routeURL: URL?` ; `GPXParser.points(from:)`.
- Produces: `CompanionWorkoutsView(viewModel:)`, `CompanionRouteMapView(routeURL:)`.

`WorkoutsViewModel` n'a **aucun test**, c'est un manque relevé dans le backlog
du 2026-08-24. Cette tâche le comble.

- [ ] **Step 1: Écrire les tests du view model**

`CompanionTests/WorkoutsViewModelTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Premiers tests de `WorkoutsViewModel` — manque relevé dans le backlog du
/// 2026-08-24 et jamais comblé.
@MainActor
final class WorkoutsViewModelTests: XCTestCase {
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func workout(daysAgo: Int, km: Double, minutes: Double, kcal: Double,
                         now: Date, calendar: Calendar) -> Workout {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                       duration: minutes, durationUnit: "min",
                       totalDistance: km, totalDistanceUnit: "km",
                       totalEnergyBurned: kcal, totalEnergyBurnedUnit: "kcal",
                       startDate: start, endDate: start.addingTimeInterval(minutes * 60),
                       routeFileName: nil)
    }

    func test_load_listsRecentWorkoutsMostRecentFirst() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        _ = try store.insertWorkouts([
            workout(daysAgo: 1, km: 8, minutes: 40, kcal: 500, now: now, calendar: calendar),
            workout(daysAgo: 5, km: 12, minutes: 65, kcal: 800, now: now, calendar: calendar)
        ])

        let viewModel = WorkoutsViewModel(store: store,
                                          routeStore: RouteStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())),
                                          now: { now })
        try viewModel.load()

        XCTAssertEqual(viewModel.recentWorkouts.count, 2)
        let first = try XCTUnwrap(viewModel.recentWorkouts.first)
        XCTAssertEqual(first.distanceKm, 8, "la plus récente d'abord")
        XCTAssertEqual(first.minutes, 40)
        XCTAssertEqual(first.energyKcal, 500)
    }

    func test_load_withNoWorkout_leavesEverythingEmptyWithoutThrowing() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = WorkoutsViewModel(store: store,
                                          routeStore: RouteStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())),
                                          now: { now })
        try viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.recentWorkouts.isEmpty)
        XCTAssertEqual(viewModel.thisWeekCount, 0)
    }
}
```

L'ordre attendu a été vérifié dans le code, pas supposé :
`HealthStore.workouts` fait `ORDER BY startDate` (croissant) et
`WorkoutsViewModel.load()` applique `.suffix(25).reversed()` — la plus
récente arrive donc bien en tête.

- [ ] **Step 2: Lancer, falsifier, commiter les tests**

Attendu : `Executed 87 tests, with 0 failures`. Mutation : dans
`WorkoutsViewModel.load()`, tronquer `recentWorkouts` à un élément — le
premier test tombe. Restaurer, **relire le fichier**, puis commiter.

- [ ] **Step 3: Écrire la carte de trace**

`Companion/Views/CompanionRouteMapView.swift` :

```swift
import SwiftUI
import MapKit

/// Trace GPS d'une séance, lue depuis le fichier GPX local. Équivalent iOS de
/// `RouteMapView` (macOS) : même parseur partagé, sans le `.help()` qui
/// n'existe pas sur iPhone.
struct CompanionRouteMapView: View {
    let routeURL: URL
    @State private var points: [CLLocationCoordinate2D] = []

    var body: some View {
        Group {
            if points.isEmpty {
                ProgressView()
                    .frame(height: 180)
            } else {
                Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
                    MapPolyline(coordinates: points)
                        .stroke(.orange, lineWidth: 3)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Trace GPS de la séance")
            }
        }
        .task(id: routeURL) {
            let url = routeURL
            points = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return [RoutePoint]() }
                return GPXParser.points(from: data)
            }.value.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }
}
```

`GPXParser.points(from:)` rend des `RoutePoint` (`latitude`/`longitude`), pas
des `CLLocationCoordinate2D` — d'où la conversion à l'arrivée, comme le fait
`RouteMapView` sur le Mac. La conversion est hors du `Task.detached` :
`CLLocationCoordinate2D` n'est pas `Sendable`, la franchir ferait échouer la
compilation.

- [ ] **Step 4: Écrire l'écran Séances**

`Companion/Views/CompanionWorkoutsView.swift` : une liste de cartes, une par
séance, avec le libellé, la date, et les valeurs disponibles — durée, distance,
énergie, FC moyenne — chacune affichée **seulement si elle existe** (`if let`),
jamais de zéro fabriqué. Une séance qui a une trace affiche un bouton
« Trace GPS » qui déplie `CompanionRouteMapView`. En tête, une carte de
synthèse : nombre de séances de la semaine, minutes, kcal.

```swift
import SwiftUI

/// Sous-écran « Séances » de l'onglet Entraînement : les sorties récentes,
/// leurs chiffres et leurs traces GPS, lues localement.
struct CompanionWorkoutsView: View {
    @ObservedObject var viewModel: WorkoutsViewModel
    @State private var expanded: Date?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if viewModel.recentWorkouts.isEmpty {
                    ContentUnavailableView(
                        "Aucune séance",
                        systemImage: "figure.run",
                        description: Text("Vos sorties enregistrées par la montre apparaîtront ici.")
                    )
                    .padding(.top, 40)
                } else {
                    weekCard
                    ForEach(viewModel.recentWorkouts, id: \.startDate) { workout in
                        workoutCard(workout)
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

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cette semaine", systemImage: "calendar")
                .font(.headline)
            Text("\(viewModel.thisWeekCount) séance(s) · \(Int(viewModel.thisWeekMinutes.rounded())) min · \(Int(viewModel.thisWeekKcal.rounded())) kcal")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func workoutCard(_ workout: WorkoutItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workout.label).font(.headline)
            Text(workout.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let minutes = workout.minutes {
                    Text("\(Int(minutes.rounded())) min")
                }
                if let km = workout.distanceKm {
                    Text("\(km.formatted(.number.precision(.fractionLength(1)))) km")
                }
                if let kcal = workout.energyKcal {
                    Text("\(Int(kcal.rounded())) kcal")
                }
                if let hr = workout.averageHeartRate {
                    Text("\(Int(hr.rounded())) bpm")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if let routeURL = workout.routeURL {
                Button {
                    expanded = expanded == workout.startDate ? nil : workout.startDate
                } label: {
                    Label(expanded == workout.startDate ? "Masquer la trace" : "Trace GPS",
                          systemImage: "map")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                if expanded == workout.startDate {
                    CompanionRouteMapView(routeURL: routeURL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 5: Brancher la navigation**

Dans `CompanionApp`, construire `WorkoutsViewModel(store: advisorStore,
routeStore: localRouteStore)` — **le `RouteStore` du conteneur**, celui de
`LocalStore`, pas le défaut : `CompanionImporter` y écrit les GPX des séances
lues dans HealthKit (`LocalStore.routeStore` = `<Application Support>/routes`),
alors que `RouteStore()` par défaut pointe ailleurs
(`<Application Support>/HealthCheck/routes`) et ne trouverait jamais un
fichier. Ajouter une `let localRouteStore: RouteStore` à `CompanionApp`,
remplie depuis `localStore.routeStore` exactement comme `advisorStore` l'est
déjà ; dans la branche d'échec, `RouteStore()` suffit — sans `LocalStore` il
n'y a de toute façon aucune séance à afficher.

Dans `CompanionTrainingView`, ajouter en bas du `body` :

```swift
                NavigationLink {
                    CompanionWorkoutsView(viewModel: workoutsViewModel)
                        .navigationTitle("Séances")
                } label: {
                    Label("Voir mes séances", systemImage: "list.bullet")
                }
                .padding()
```

- [ ] **Step 6: Compiler, installer, contrôler à l'écran**

Suite iOS complète, puis installation sur l'iPhone **déverrouillé** — et le
rester : l'installation peut réussir et le lancement échouer dix secondes plus
tard si l'écran se verrouille entre les deux.

À l'écran : la charge et le VO2max s'affichent, le plan est passé dans cet
onglet avec ses cases à cocher fonctionnelles, « Voir mes séances » ouvre la
liste, et une séance avec trace déplie une carte.

**Vérifier le stock de traces avant de conclure quoi que ce soit sur les
cartes.** `CompanionImporter` enregistre `routeFileName` même quand
l'écriture du GPX a échoué (self-healing assumé), et `RouteStore.url` rend
alors `nil` : la séance n'affiche aucun bouton — indiscernable à l'œil d'une
séance qui n'a jamais eu de trace. L'absence de carte ne prouve donc rien.
Compter les fichiers d'abord :

```bash
xcrun devicectl device info files --device <UDID> \
    --domain-type appDataContainer \
    --domain-identifier fr.vincentlauriat.healthcheck.companion \
    --username mobile --subdirectory "Library/Application Support/routes"
```

Constaté le 2026-09-02 : **25 traces**, de 62 Ko à 368 Ko, la plus récente du
matin même. Deux fichiers font 296 octets (24 et 25/08) — des traces vides,
qui doivent afficher « Trace illisible » et non une carte blanche.

- [ ] **Step 7: Lancer la suite macOS**

```bash
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Executed|failed"
```

Attendu : `Executed 279 tests, with 0 failures`. SP3 ne modifie
définitivement aucun fichier partagé — un écart ici ne serait donc pas une
régression fonctionnelle mais la trace d'une **mutation non restaurée**.
C'est le détecteur le moins cher du défaut qui a frappé deux fois pendant le
SP2b : la restauration lancée mais jamais vérifiée.

- [ ] **Step 8: Documentation et commit**

`ARCHITECTURE.md` et `ARCHITECTURE_EN.md` (miroirs), `CHANGES.md`, `TODOS.md`,
`COMMANDS.md`, `MEMORY.md`, `PLAN.md` — la convention `~/DevApps/CLAUDE.md`
les veut tous à jour dans le même tour que la modification.

```bash
git add Companion CompanionTests ARCHITECTURE.md ARCHITECTURE_EN.md docs
git commit -m "feat(companion): add the Seances screen with GPS routes"
```

---

## Definition of done

- L'onglet Entraînement montre charge, ACWR, alertes, VO2max et le plan mis en
  cache ; l'onglet Synchro ne contient plus que l'appairage et l'envoi.
- Un sous-écran Séances liste les sorties avec leurs chiffres et leurs traces.
- 87 tests iOS, 279 macOS inchangés ; `WorkoutsViewModel` a enfin des tests.
- Chaque garde vue échouer contre sa mutation, fichier relu avant commit.
- Contrôle à l'écran fait, documentation à jour.
