# Companion SP1 — Fondation : view models partagés et navigation à cinq onglets

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** rendre les sept view models d'analyse du Mac disponibles à la cible
iOS et poser la navigation à cinq onglets du Companion, sans changer aucun
comportement existant.

**Architecture:** déplacement pur de `HealthCheck/ViewModels/` vers
`HealthCheckShared/ViewModels/` — les deux cibles déclarent leurs sources par
chemin dans `project.yml`, donc le seul fait de déplacer les fichiers suffit à
les compiler des deux côtés. Les vues restent propres à chaque plateforme :
côté iOS, `CompanionRootView` passe de deux à cinq onglets, dont quatre
affichent pour l'instant un écran d'attente explicite. L'onglet Accueil garde
exactement les trois cartes actuelles ; sa bascule sur `DashboardViewModel`
appartient au SP2.

**Tech Stack:** Swift 5.9, SwiftUI, XcodeGen, XCTest, GRDB.

**Spec:** `docs/superpowers/specs/2026-09-02-companion-full-analysis-design.md`

## Global Constraints

- Interface et messages utilisateur en **français**, accents complets.
  Identifiants, commits et fichiers de doc en **anglais**.
- Toute garde de non-régression doit avoir été **vue échouer** contre le
  défaut qu'elle surveille avant d'être acceptée.
- `today`/`now` et `calendar` sont toujours des paramètres injectés. Ne jamais
  appeler `Date()` dans un test.
- `HealthCheck.xcodeproj` est généré et gitignoré : après tout déplacement ou
  ajout de fichier, lancer `xcodegen generate`.
- Tests macOS **avec** `CODE_SIGNING_ALLOWED=NO`, tests iOS **sans** ce
  drapeau (sinon l'app hôte perd l'accès au trousseau, `errSecMissingEntitlement`).
- Lister les simulateurs avec `xcrun simctl list devices available` plutôt
  que d'en supposer un ; ce plan utilise `iPhone 17`, présent au 2026-09-02.
- Référence de non-régression avant de commencer : **279 tests macOS**,
  **71 tests iOS**.

---

### Task 1: Remonter les sept view models d'analyse dans HealthCheckShared

**Files:**
- Create: `CompanionTests/SharedViewModelsAvailabilityTests.swift`
- Move: `HealthCheck/ViewModels/DashboardViewModel.swift` → `HealthCheckShared/ViewModels/DashboardViewModel.swift`
- Move: `HealthCheck/ViewModels/ActivityViewModel.swift` → `HealthCheckShared/ViewModels/ActivityViewModel.swift`
- Move: `HealthCheck/ViewModels/SleepViewModel.swift` → `HealthCheckShared/ViewModels/SleepViewModel.swift`
- Move: `HealthCheck/ViewModels/TrendsViewModel.swift` → `HealthCheckShared/ViewModels/TrendsViewModel.swift`
- Move: `HealthCheck/ViewModels/CorrelationsViewModel.swift` → `HealthCheckShared/ViewModels/CorrelationsViewModel.swift`
- Move: `HealthCheck/ViewModels/TrainingViewModel.swift` → `HealthCheckShared/ViewModels/TrainingViewModel.swift`
- Move: `HealthCheck/ViewModels/WorkoutsViewModel.swift` → `HealthCheckShared/ViewModels/WorkoutsViewModel.swift`

**Interfaces:**
- Consumes: `HealthStore`, `SourcePriorityResolver`, `RouteStore` (déjà dans `HealthCheckShared/`).
- Produces: sept classes `@MainActor ObservableObject` visibles des deux
  cibles, signatures inchangées —
  `DashboardViewModel(store:resolver:calendar:now:).load() throws`,
  `ActivityViewModel(store:resolver:calendar:now:).load() throws`,
  `SleepViewModel(store:resolver:calendar:now:).load() throws`,
  `TrendsViewModel(store:resolver:calendar:now:).load(period: TrendPeriod) throws`,
  `CorrelationsViewModel(store:resolver:calendar:now:).load() throws`,
  `TrainingViewModel(store:calendar:now:).load(readiness: ReadinessScore?) throws`,
  `WorkoutsViewModel(store:routeStore:calendar:now:).load() throws`.
  `TrendPeriod` monte avec `TrendsViewModel.swift`, où il est défini.

- [ ] **Step 1: Écrire la garde du déplacement**

Créer `CompanionTests/SharedViewModelsAvailabilityTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Garde du déplacement (SP1) : ces sept view models vivaient dans
/// `HealthCheck/ViewModels/`, compilé par la seule cible macOS. Tant qu'ils ne
/// sont pas dans `HealthCheckShared/ViewModels/`, ce fichier ne compile pas —
/// c'est la forme que prend l'échec attendu, et elle est sans ambiguïté.
///
/// Le store est vide à dessein : ce test ne vérifie pas les calculs (leurs
/// propres tests s'en chargent côté macOS), seulement que les sept view models
/// existent côté iPhone et traversent un `load()` sans lever sur une base
/// neuve — l'état exact d'un Companion fraîchement installé.
@MainActor
final class SharedViewModelsAvailabilityTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    /// 2026-08-24 04:26 UTC. Fixe : ce dépôt a déjà connu des échecs à minuit.
    private let fixedNow = Date(timeIntervalSince1970: 1_756_009_600)

    func test_theSevenAnalysisViewModels_loadOnIOSAgainstAnEmptyStore() throws {
        let store = try HealthStore(path: ":memory:")
        let routes = RouteStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let now = fixedNow

        try DashboardViewModel(store: store, resolver: resolver, now: { now }).load()
        try ActivityViewModel(store: store, resolver: resolver, now: { now }).load()
        try SleepViewModel(store: store, resolver: resolver, now: { now }).load()
        try TrendsViewModel(store: store, resolver: resolver, now: { now }).load(period: .sixMonths)
        try CorrelationsViewModel(store: store, resolver: resolver, now: { now }).load()
        try TrainingViewModel(store: store, now: { now }).load()
        try WorkoutsViewModel(store: store, routeStore: routes, now: { now }).load()
    }
}
```

- [ ] **Step 2: Lancer les tests iOS et constater l'échec**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed"
```

Attendu : échec de compilation, `cannot find 'DashboardViewModel' in scope`
(et les six autres). C'est l'échec qui valide la garde.

- [ ] **Step 3: Déplacer les sept fichiers**

```bash
mkdir -p HealthCheckShared/ViewModels
git mv HealthCheck/ViewModels/DashboardViewModel.swift HealthCheckShared/ViewModels/
git mv HealthCheck/ViewModels/ActivityViewModel.swift HealthCheckShared/ViewModels/
git mv HealthCheck/ViewModels/SleepViewModel.swift HealthCheckShared/ViewModels/
git mv HealthCheck/ViewModels/TrendsViewModel.swift HealthCheckShared/ViewModels/
git mv HealthCheck/ViewModels/CorrelationsViewModel.swift HealthCheckShared/ViewModels/
git mv HealthCheck/ViewModels/TrainingViewModel.swift HealthCheckShared/ViewModels/
git mv HealthCheck/ViewModels/WorkoutsViewModel.swift HealthCheckShared/ViewModels/
xcodegen generate
```

`HealthCheck/ViewModels/` conserve `BodyViewModel`, `ImportViewModel`,
`WithingsViewModel` et `CompanionViewModel` : ils dépendent de l'API Withings,
de l'import zip ou du serveur d'appairage, tous exclusivement macOS.

- [ ] **Step 4: Lancer les tests iOS et constater le succès**

```bash
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed"
```

Attendu : `Executed 72 tests, with 0 failures` (71 + la nouvelle garde).

Si l'un des `load()` lève sur une base vide, ce n'est pas le test qu'il faut
corriger : c'est un view model qui suppose des données présentes, et il faut
le signaler avant d'aller plus loin — le Companion démarre toujours sur une
base vide à la première installation.

- [ ] **Step 5: Vérifier que le Mac n'a rien perdu**

```bash
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|Executed"
```

Attendu : `Executed 279 tests, with 0 failures`, exactement comme avant le
déplacement. Aucun test n'a été modifié : c'est la garde du déplacement
lui-même.

- [ ] **Step 6: Commit**

```bash
git add -A HealthCheck/ViewModels HealthCheckShared/ViewModels CompanionTests
git commit -m "refactor: move the seven analysis view models into HealthCheckShared

They only ever depended on HealthStore, SourcePriorityResolver and
RouteStore, all already shared. Moving them makes the iOS target compile
the same calculation layer as the Mac instead of growing a second one.

279/279 macOS tests unchanged, 72/72 iOS."
```

---

### Task 2: Garde du poids absent sur l'iPhone

**Files:**
- Modify: `CompanionTests/SharedViewModelsAvailabilityTests.swift`

**Interfaces:**
- Consumes: `DashboardViewModel` (Task 1), `HealthStore.insertRecords`,
  `HealthRecord`.
- Produces: rien de nouveau — cette tâche verrouille un comportement.

`DashboardViewModel` appelle `WeightEngine`, ce que `CompanionAdvisorViewModel`
contournait jusqu'ici en passant `weightAlert: nil` en dur. Sur l'iPhone, la
base ne contient aucune pesée avant le SP5. Le comportement attendu est que le
tableau de bord se calcule normalement et n'invente aucune alerte de poids.
Rien ne le garantit aujourd'hui côté iOS.

- [ ] **Step 1: Écrire la garde**

Ajouter dans `SharedViewModelsAvailabilityTests` :

```swift
    /// Le tableau de bord partagé doit produire son score de forme sur une base
    /// sans la moindre pesée — c'est l'état de l'iPhone jusqu'au SP5 — sans
    /// fabriquer d'alerte de poids au passage.
    func test_dashboard_onAStoreWithoutAnyWeight_scoresReadinessAndRaisesNoWeightAlert() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        // Baseline de FC repos : 10 jours à 60 bpm, puis 66 aujourd'hui (+10 %).
        var records: [HealthRecord] = []
        for day in 1...10 {
            let date = calendar.date(byAdding: .day, value: -day, to: now)!
            records.append(HealthRecord(type: "HKQuantityTypeIdentifierRestingHeartRate",
                                        sourceName: "Watch", device: nil, unit: "count/min",
                                        value: 60, startDate: date,
                                        endDate: date.addingTimeInterval(300), creationDate: date))
        }
        records.append(HealthRecord(type: "HKQuantityTypeIdentifierRestingHeartRate",
                                     sourceName: "Watch", device: nil, unit: "count/min",
                                     value: 66, startDate: now,
                                     endDate: now.addingTimeInterval(300), creationDate: now))
        try store.insertRecords(records)

        let viewModel = DashboardViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load()

        XCTAssertNotNil(viewModel.readiness,
                        "le score de forme ne dépend pas du poids et doit être calculé")
        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                       "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.",
                       "sans pesée en base, le conseil du jour doit rester le message générique du palier : "
                       + "une alerte de poids le remplacerait")
    }
```

`DashboardViewModel` ne publie pas d'alerte de poids : il calcule
`WeightEngine.safetyAlert` et la passe à `DailyAdviceEngine.advise`, qui
substitue le message de la première alerte `.warning` au message générique
dès lors que le palier n'est pas `.opportunite`. C'est donc `dailyAdvice`
qu'il faut observer — et c'est ce qui rend la garde falsifiable à l'étape
suivante.

- [ ] **Step 2: Lancer le test et constater qu'il passe**

```bash
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed"
```

Attendu : `Executed 73 tests, with 0 failures`.

- [ ] **Step 3: Falsifier la garde**

Dans `HealthCheckShared/Analysis/WeightEngine.swift`, faire rendre à
`safetyAlert` une alerte `.warning` inconditionnelle, en première ligne du
corps, avant tout calcul :

```swift
        return LoadAlert(severity: .warning, message: "Mutation de falsification")
```

Relancer la suite iOS : le palier reste `.repos`, donc `DailyAdviceEngine`
substitue « Mutation de falsification » au message générique et **ce test-là**
échoue sur l'assertion de message. Restaurer le fichier
(`git checkout -- HealthCheckShared/Analysis/WeightEngine.swift`), relancer,
vérifier le retour au vert.

Si la mutation ne fait rien échouer, la garde ne surveille rien : tester
`WeightEngine` directement plutôt qu'à travers le view model.

- [ ] **Step 4: Commit**

```bash
git add CompanionTests/SharedViewModelsAvailabilityTests.swift
git commit -m "test: pin the weight-free dashboard behaviour on iOS

DashboardViewModel calls WeightEngine, which CompanionAdvisorViewModel used
to bypass with a hardcoded nil. On a store with no weigh-in - the iPhone's
state until SP5 - readiness must still be scored and no weight alert
invented. Seen failing against a WeightEngine that always alerts."
```

---

### Task 3: Navigation à cinq onglets et Synchro dans Réglages

**Files:**
- Create: `Companion/Views/CompanionPlaceholderView.swift`
- Create: `Companion/Views/CompanionActivityView.swift`
- Create: `Companion/Views/CompanionSleepView.swift`
- Create: `Companion/Views/CompanionTrainingView.swift`
- Create: `Companion/Views/CompanionBodyView.swift`
- Modify: `Companion/CompanionRootView.swift`

**Interfaces:**
- Consumes: `CompanionAdvisorViewModel`, `CompanionViewModel`,
  `CompanionAdvisorView`, `CompanionSyncView` (tous existants, inchangés).
- Produces: `CompanionPlaceholderView(title:systemImage:)`, réutilisée par les
  quatre écrans d'attente ; `CompanionRootView` à cinq onglets.

Les vues ne sont pas testées unitairement : ce dépôt n'a pas de harnais de
vue, et en fabriquer un pour ce chantier serait hors sujet. La vérification de
cette tâche est la compilation, la suite iOS complète, puis un contrôle à
l'écran sur l'iPhone (Step 5).

- [ ] **Step 1: Écrire l'écran d'attente réutilisable**

`Companion/Views/CompanionPlaceholderView.swift` :

```swift
import SwiftUI

/// Écran d'attente des onglets posés au SP1 et remplis aux sous-projets
/// suivants. Dit ce qui manque plutôt que d'afficher un vide qu'on pourrait
/// prendre pour une panne.
struct CompanionPlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text("Cet écran arrive dans une prochaine version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 2: Écrire les quatre écrans d'attente**

`Companion/Views/CompanionActivityView.swift` :

```swift
import SwiftUI

/// Onglet « Activité » — rempli au SP2 (`ActivityViewModel`).
struct CompanionActivityView: View {
    var body: some View {
        CompanionPlaceholderView(title: "Activité", systemImage: "figure.walk")
    }
}
```

`Companion/Views/CompanionSleepView.swift` :

```swift
import SwiftUI

/// Onglet « Sommeil » — rempli au SP2 (`SleepViewModel`).
struct CompanionSleepView: View {
    var body: some View {
        CompanionPlaceholderView(title: "Sommeil", systemImage: "moon.zzz.fill")
    }
}
```

`Companion/Views/CompanionTrainingView.swift` :

```swift
import SwiftUI

/// Onglet « Entraînement » — rempli au SP3 (`TrainingViewModel`, `WorkoutsViewModel`).
struct CompanionTrainingView: View {
    var body: some View {
        CompanionPlaceholderView(title: "Entraînement", systemImage: "figure.run")
    }
}
```

`Companion/Views/CompanionBodyView.swift` :

```swift
import SwiftUI

/// Onglet « Corps » — rempli au SP5, quand le poids sera lu depuis HealthKit.
struct CompanionBodyView: View {
    var body: some View {
        CompanionPlaceholderView(title: "Corps", systemImage: "figure")
    }
}
```

- [ ] **Step 3: Réécrire CompanionRootView**

Remplacer intégralement `Companion/CompanionRootView.swift` :

```swift
import SwiftUI

/// Shell de navigation à cinq onglets. « Accueil » est autonome (calcul
/// local, indépendant de l'appairage) ; les quatre autres sont posés ici et
/// remplis aux sous-projets suivants. L'appairage et l'envoi au Mac, qui
/// étaient un onglet, deviennent un écran de réglages : c'est une
/// configuration, pas une destination quotidienne.
struct CompanionRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var advisorViewModel: CompanionAdvisorViewModel
    @State private var showingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                CompanionAdvisorView(viewModel: advisorViewModel, lastSyncDate: viewModel.lastSyncDate)
                    .navigationTitle("Accueil")
                    .toolbar {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Réglages", systemImage: "gearshape")
                        }
                    }
            }
            .tabItem { Label("Accueil", systemImage: "heart.text.square") }

            NavigationStack {
                CompanionActivityView().navigationTitle("Activité")
            }
            .tabItem { Label("Activité", systemImage: "figure.walk") }

            NavigationStack {
                CompanionSleepView().navigationTitle("Sommeil")
            }
            .tabItem { Label("Sommeil", systemImage: "moon.zzz.fill") }

            NavigationStack {
                CompanionTrainingView().navigationTitle("Entraînement")
            }
            .tabItem { Label("Entraînement", systemImage: "figure.run") }

            NavigationStack {
                CompanionBodyView().navigationTitle("Corps")
            }
            .tabItem { Label("Corps", systemImage: "figure") }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                CompanionSyncView(viewModel: viewModel)
                    .navigationTitle("Réglages")
                    .toolbar {
                        Button("Fermer") { showingSettings = false }
                    }
            }
        }
    }
}
```

- [ ] **Step 4: Générer, compiler, lancer la suite iOS**

```bash
xcodegen generate
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "error:|Executed"
```

Attendu : `Executed 73 tests, with 0 failures`. Aucun test ne porte sur les
vues ; ce qu'on vérifie ici, c'est que rien n'est cassé par la réécriture.

- [ ] **Step 5: Installer sur l'iPhone et contrôler à l'écran**

L'iPhone doit être **déverrouillé** : verrouillé, le lancement est refusé
(`BSErrorCodeDescription = Locked`) et HealthKit reste illisible.

```bash
xcodebuild -scheme HealthCheckCompanion -configuration Debug \
    -destination 'id=30EEDEE3-2740-529B-95CA-889A2F829410' \
    -derivedDataPath build/DeviceBuild -allowProvisioningUpdates build
xcrun devicectl device install app --device 30EEDEE3-2740-529B-95CA-889A2F829410 \
    build/DeviceBuild/Build/Products/Debug-iphoneos/HealthCheckCompanion.app
xcrun devicectl device process launch --terminate-existing \
    --device 30EEDEE3-2740-529B-95CA-889A2F829410 fr.vincentlauriat.healthcheck.companion
```

À vérifier à l'écran : cinq onglets présents, Accueil affiche toujours ses
trois cartes, le bouton Réglages ouvre l'écran de synchro et le bouton Fermer
le referme, l'appairage et l'envoi au Mac fonctionnent toujours depuis cet
écran.

- [ ] **Step 6: Mettre la documentation à jour**

Dans le même tour que le code, jamais en différé :

- `ARCHITECTURE.md` et `ARCHITECTURE_EN.md` : la section Companion décrit
  aujourd'hui « un `TabView` à deux onglets » — la remplacer par les cinq
  onglets et Réglages, et signaler que les view models d'analyse vivent
  désormais dans `HealthCheckShared/ViewModels/`, partagés par les deux
  cibles. Les deux fichiers sont des miroirs stricts : les éditer ensemble.
- `CHANGES.md` : une entrée datée du jour, sections `Changed` (déplacement
  des view models, navigation) et `Verified` (compte de tests, mutations de
  falsification).
- `TODOS.md` : cocher « SP1 — Fondation » dans la section « Companion = mêmes
  écrans que le Mac ».

- [ ] **Step 7: Commit**

```bash
git add Companion/Views Companion/CompanionRootView.swift ARCHITECTURE.md ARCHITECTURE_EN.md
git commit -m "feat(companion): lay out the five-tab shell and move sync into settings

Accueil keeps exactly its current three cards - switching it to the shared
DashboardViewModel belongs to SP2. The four new tabs say what is coming
rather than showing a blank screen that reads as a failure. Pairing and
pushing to the Mac move behind a settings button: they are configuration,
not a daily destination."
```

---

## Definition of done

- `HealthCheckShared/ViewModels/` contient les sept view models d'analyse ;
  `HealthCheck/ViewModels/` ne garde que Body, Import, Withings et Companion.
- 279 tests macOS inchangés, 73 tests iOS.
- Les deux gardes ajoutées ont été vues échouer : la première par la
  compilation avant déplacement, la seconde par une mutation de `WeightEngine`.
- Le Companion affiche cinq onglets sur l'iPhone, Accueil inchangé, Synchro
  accessible depuis Réglages.
- `ARCHITECTURE.md` et `ARCHITECTURE_EN.md` décrivent la nouvelle arborescence
  et la navigation à cinq onglets ; `CHANGES.md` et `TODOS.md` sont à jour.
