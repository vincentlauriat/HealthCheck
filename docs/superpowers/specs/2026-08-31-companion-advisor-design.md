# HealthCheck — Écran advisor sur Companion (iPhone)

**Décisions prises avec Vincent (2026-08-31) :** sous-projet 4 de la
roadmap advisor/iPhone, au-delà des 4 sous-projets originels (0, fondation
d'analyse partagée ; 1, conseiller VO2max/entraînement ; 2, conseil du jour
transverse ; 3, conseiller poids — tous mergés). Le sous-projet 0 posait
la fondation technique (`HealthCheckShared/Analysis/` compile côté iOS)
« prérequis pour une expérience advisor sur iPhone qui fonctionne sans le
Mac joignable » — mais aucun des sous-projets 1 à 3 n'a construit cet
écran : les moteurs compilent côté Companion, rien n'y est câblé. Ce
document réalise cette promesse. Comme les sous-projets 2 et 3, résultat
d'un brainstorming complet mené avec Vincent dans cette conversation,
section par section, chaque décision approuvée explicitement avant d'être
actée.

**Correction post-approbation (2026-09-01) :** la première version de ce
document incluait le poids (`WeightEngine`, lecture HealthKit de
`bodyMass`). En lisant `CompanionTests/HKMapperTests.swift` avant
d'écrire le plan, un test existant du sous-projet 0 a été trouvé :
`test_unknownQuantityType_isDropped` vérifie explicitement qu'un
échantillon `bodyMass` est ignoré, avec le commentaire « balance =
territoire Withings ». Vincent a confirmé que cette règle tient toujours
— le poids reste exclusivement un flux Withings côté Mac, jamais lu via
HealthKit sur iPhone. Le poids est donc retiré du périmètre de ce
sous-projet ; ce document est corrigé en conséquence (§4/§7 de la version
précédente supprimées, écran ramené à 3 cartes).

## 1. Context and motivation

`HealthCheckCompanion` (cible iOS) est aujourd'hui un écran unique
(`CompanionRootView`) : appairage au Mac, statut de synchronisation, cache
local du plan d'entraînement avec cases à cocher par séance. Il synchronise
déjà des données HealthKit vers son propre `HealthStore` local
(`Companion/LocalStore.swift`), indépendamment de l'appairage — la lecture
HealthKit et l'enregistrement du sync en arrière-plan se font au lancement
de l'app (`CompanionApp.body`, `.task` non conditionné par `isPaired`).
Mais rien ne lit jamais ce store localement : les données ne servent qu'à
être poussées vers le Mac (`SyncEngine.syncAll()` → `MacClient`).

`HealthCheckShared/Analysis/` contient déjà `HealthScoreEngine`,
`TrainingLoadMonitor`, `VO2MaxEngine`, `DailyAdviceEngine` — tous purs,
tous confirmés présents dans les sources de la cible `HealthCheckCompanion`
(`project.pbxproj`, cible `3409D6FA38E72FFD49B6FE58`). Ce sous-projet leur
donne un consommateur côté iPhone. (`WeightEngine` compile aussi côté iOS,
mais reste hors périmètre — §2.)

Une lacune empêche de construire cet écran aujourd'hui : **le
`HealthStore` local est jeté après l'ouverture.** `CompanionApp.init`
(`Companion/CompanionApp.swift:18-22`) ne conserve que
`LocalStore().importer`, pas la struct `LocalStore` complète — rien ne
peut donc relire `healthStore` pour construire un écran.

## 2. Goals / non-goals

**Goals :**
- Un nouveau `CompanionAdvisorViewModel` (iOS) qui réplique la logique de
  `DashboardViewModel.loadWellness()` (macOS) — mêmes moteurs, même
  enchaînement de calcul — mais lit le `HealthStore` local du téléphone,
  jamais le Mac.
- Un nouvel onglet « Conseils » dans l'app, indépendant de l'état
  d'appairage : score de forme, carte « Conseil du jour », tendance
  VO2max.
- Correctif du `LocalStore` jeté (§1) — prérequis pour tout le reste.

**Non-goals :**
- **Pas de poids.** `WeightEngine` n'est pas câblé dans ce sous-projet —
  ni tendance, ni alerte de sécurité, ni lecture HealthKit de `bodyMass`.
  Règle confirmée par Vincent (2026-09-01) : le poids reste un flux
  Withings exclusivement côté Mac (`CompanionTests/HKMapperTests.swift`,
  `test_unknownQuantityType_isDropped`, « balance = territoire Withings »)
  — pas seulement une omission du sous-projet 0 à corriger, une règle
  toujours voulue. `DailyAdviceEngine.advise(...)` est donc appelé avec
  `weightAlert: nil` en permanence sur cet écran.
- **Pas de composition corporelle détaillée.** Muscle, hydratation, os,
  graisse viscérale (`WithingsMapper.*Type`) sont des données de l'API
  Withings, jamais présentes dans HealthKit — structurellement
  impossibles à répliquer sur Companion sans relayer l'API Withings
  elle-même. Hors périmètre.
- **Pas de plan d'entraînement dans `TrainingLoadMonitor.assess(...)`.**
  Appelé avec `plan: nil`, comme `DashboardViewModel` — le cache local du
  plan (`CompanionViewModel.trainingPlan`) est une structure différente
  (JSON + cases cochées) du modèle `TrainingPlan` attendu par le moteur ;
  faire le pont entre les deux est hors périmètre.
- **Pas de nouveau seuil ni de nouveau moteur.** Composition pure des
  mêmes verdicts que le Mac — aucune métrique recalculée différemment.
- **Pas de relais depuis le Mac.** Explicitement écarté en approche (§3
  ci-dessous) — romprait la promesse d'autonomie du sous-projet 0.

## 3. Architecture overview — approche retenue

**Calcul entièrement local**, à partir du `HealthStore` propre au
Companion. `CompanionAdvisorViewModel` (nouveau, `Companion/`) est
construit avec ce `HealthStore` local (via le `LocalStore` retenu par
`CompanionApp`), un `SourcePriorityResolver(priority: ["Watch", "iPhone"])`
— même littéral que `HealthCheckApp.swift:57` sur le Mac, aucun état à
synchroniser entre les deux apps — `calendar: .current`, `now: Date.init`.

**Alternative écartée : relais depuis le Mac.** Le Mac pourrait calculer
`readiness`/`DailyAdvice`/tendances et les pousser via un nouvel endpoint
de synchro, Companion se contentant d'afficher. Plus simple à coder, mais
recrée exactement la dépendance que le sous-projet 0 cherche à éliminer —
« ça marche sans le Mac joignable » devient faux. Écarté.

**Alternative écartée : cache hybride.** Calcul local par défaut, mais le
Mac pousse un résumé pré-calculé pendant la synchro normale pour améliorer
la fraîcheur (ou couvrir les cas où le Mac dispose de plus d'historique).
Ajoute une question de fraîcheur/conflit (quelle source gagne, staleness)
sans bénéfice net pour cette première itération — reporté (YAGNI).

## 4. Correctif préalable — LocalStore retenu

`CompanionApp.init` (`Companion/CompanionApp.swift:18-22`) doit conserver
la struct `LocalStore` complète, pas seulement `.importer`. Suit le motif
déjà établi côté Mac pour ce type précis de panne
(`HealthCheckApp.swift:41-56`, `store = HealthStore(unavailable: ())` +
`failure: Error?` gardés séparément) plutôt qu'un optionnel :

```swift
// Avant :
let localImporter: LocalIngesting
do {
    localImporter = try LocalStore().importer
} catch {
    os_log(.error, "LocalStore indisponible, mode relais seul: %{public}@", String(describing: error))
    localImporter = NoOpImporter()
}

// Après :
let advisorStore: HealthStore
let localImporter: LocalIngesting
do {
    let store = try LocalStore()
    advisorStore = store.healthStore
    localImporter = store.importer
} catch {
    os_log(.error, "LocalStore indisponible, mode relais seul: %{public}@", String(describing: error))
    advisorStore = HealthStore(unavailable: ())
    localImporter = NoOpImporter()
}
```

`advisorStore` (jamais optionnel — `HealthStore(unavailable: ())` en
repli, comme le Mac) est propagé à `CompanionAdvisorViewModel` au même
endroit que `viewModel` est construit aujourd'hui. Toute lecture sur ce
store de repli lève `HealthStoreError.unavailable` — `refresh()` (§5) doit
la traiter comme l'état « base indisponible » (§6), jamais la laisser
remonter.

## 5. CompanionAdvisorViewModel

Réplique `DashboardViewModel.loadWellness()`
(`HealthCheck/ViewModels/DashboardViewModel.swift:65-137`), sans les
métriques d'activité/pas propres à l'écran Accueil (hors périmètre ici)
et sans le poids (§2) :

```swift
@MainActor
final class CompanionAdvisorViewModel: ObservableObject {
    @Published private(set) var readiness: ReadinessScore?
    @Published private(set) var dailyAdvice: DailyAdvice?
    @Published private(set) var vo2Trend: VO2MaxTrend?
    @Published private(set) var hasLoaded = false
    @Published private(set) var storeUnavailable = false

    private let store: HealthStore
    private let resolver: SourcePriorityResolver
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, resolver: SourcePriorityResolver,
         calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.resolver = resolver
        self.calendar = calendar
        self.now = now
    }

    func refresh() {
        hasLoaded = true
        do {
            // ... même enchaînement que loadWellness() sans le bloc poids :
            // d30/d120/d7, hrDaily/hrvDaily/energyDaily/sleepNights,
            // split(latest/baseline), HealthScoreEngine.readiness,
            // VO2MaxEngine.trend, TrainingLoadMonitor.assess(plan: nil),
            // VO2MaxEngine.stagnationAlert,
            // DailyAdviceEngine.advise(readiness:loadAlerts:vo2MaxAlert:weightAlert: nil)
            storeUnavailable = false
        } catch is HealthStoreError {
            storeUnavailable = true
        } catch { /* autre erreur inattendue : traiter comme storeUnavailable aussi */ storeUnavailable = true }
    }
}
```

`refresh()` n'est plus `throws` : contrairement à `DashboardViewModel.load()`
(macOS, où un store indisponible empêche l'app entière de démarrer —
`HealthCheckApp` gère ce cas avant même de construire les view models,
§4), ici le store de repli est une possibilité normale de fonctionnement
que l'écran doit absorber lui-même sans propager l'erreur à l'appelant.

Signatures des moteurs déjà fixées par les sous-projets 1 à 3 — aucune
extension nécessaire. `TrainingLoadMonitor.assess(history:plan: nil,
readiness:today:calendar:)` fournit `.alerts` pour `loadAlerts`. Pas de
`WeightEngine.safetyAlert` à appeler (§2) — `trainingLoadElevated` n'a
donc pas lieu d'être calculé ici.

## 6. UI — onglet « Conseils »

Nouveau fichier `Companion/CompanionAdvisorView.swift`. Trois cartes,
mêmes moteurs et mêmes textes que le Mac (pas de nouvelle rédaction) :

1. **Forme** — `ReadinessScore.value`/`.label`.
2. **Conseil du jour** — `DailyAdvice.message`, style selon le palier
   (repos/prudence/opportunité), même carte que `DashboardView`.
3. **VO2max** — verdict de tendance + alerte de stagnation le cas échéant.

Une carte individuellement absente (ex. pas encore de VO2max mesuré) se
masque simplement — pas d'état vide par carte.

**États d'écran entier :**
- **Base locale indisponible** (`storeUnavailable == true`, `LocalStore`
  a échoué à s'ouvrir) — mirroré sur `StoreErrorView` déjà existant côté
  Mac pour la même classe de panne (corrigé le 2026-08-23) : message
  clair, pas d'écran muet.
- **Aucune donnée locale pour l'instant** (`hasLoaded == true`,
  `readiness == nil`, `storeUnavailable == false`) — couvre à la fois
  « jamais synchronisé » et « historique encore trop court » (les deux
  ont la même apparence pour l'utilisateur, pas besoin de les
  distinguer). Message : « Pas encore assez de données — synchronisez, ou
  revenez dans quelques jours. »

**Déclenchement du calcul**, même leçon que le pitfall corrigé côté Mac le
2026-08-28 (ne jamais recharger à chaque changement d'onglet) :
- Premier calcul à l'apparition de l'onglet (`.task`, gardé par
  `hasLoaded`).
- Recalcul automatique après une synchro : `CompanionAdvisorView` observe
  `syncViewModel.lastSyncDate` (`CompanionViewModel.swift:24`, déjà
  publié) via `.onChange(of:)` et appelle `advisorViewModel.refresh()` —
  pas de couplage direct entre les deux view models au-delà de cette
  observation.
- Tirer-pour-rafraîchir sur l'onglet lui-même (`.refreshable`, même motif
  que `pairedContent` en a déjà un pour le plan d'entraînement,
  `CompanionRootView.swift:71-73`).

## 7. Navigation

`CompanionRootView` restructuré : aujourd'hui `NavigationStack` unique
alternant `pairingContent`/`pairedContent` selon `isPaired`
(`CompanionRootView.swift:26-49`). Devient un `TabView` à 2 onglets, le
nouvel onglet **indépendant de `isPaired`** (§1 : la lecture HealthKit et
le sync en arrière-plan tournent déjà sans appairage) :

```swift
TabView {
    CompanionAdvisorView(viewModel: advisorViewModel)
        .tabItem { Label("Conseils", systemImage: "heart.text.square") }

    CompanionSyncView(viewModel: viewModel)  // contenu existant, déplacé
        .tabItem { Label("Synchro", systemImage: "arrow.triangle.2.circlepath") }
}
```

Refactor associé : `CompanionRootView.swift` (349 lignes aujourd'hui,
mélange déjà appairage + synchro + plan d'entraînement) devient un shell
de `TabView` fin ; tout le contenu actuel (`pairingContent`, `pairedContent`,
`syncCard`, `trainingPlanContent`, etc., y compris les `@State` et le
`.confirmationDialog` de dépairage) est déplacé tel quel — aucune logique
changée — dans un nouveau `Companion/CompanionSyncView.swift`. Justifié
par la même règle que le reste du dépôt (fichiers focalisés une seule
responsabilité) plutôt qu'ajouté par confort : ce fichier faisait déjà
plusieurs choses avant ce sous-projet, ce n'est pas ce sous-projet qui
crée le problème mais il en aggraverait la taille sans ce découpage.

## 8. Code structure

- Create: `Companion/CompanionAdvisorViewModel.swift`
- Create: `Companion/CompanionAdvisorView.swift`
- Create: `Companion/CompanionSyncView.swift` (contenu déplacé de
  `CompanionRootView.swift`, aucun changement de logique)
- Modify: `Companion/CompanionRootView.swift` (devient le shell `TabView`)
- Modify: `Companion/CompanionApp.swift` (`LocalStore` retenu, §4)
- Test: `CompanionTests/CompanionAdvisorViewModelTests.swift` (nouveau)

Aucun fichier `Companion/Sync/` modifié — le poids reste hors périmètre
(§2), donc aucun ajout de type HealthKit.

## 9. Testing strategy

`CompanionAdvisorViewModelTests.swift` suit le même gabarit que
`DashboardViewModelTests`/`BodyViewModelTests` (sous-projet 3) :
`HealthStore(path: ":memory:")`, `now:` toujours injecté, jamais de
`Date()`. Pas de protocole/mock nécessaire — contrairement à
`CompanionViewModel` (réseau), ce view model ne lit que le store local, il
n'y a pas de seam réseau à simuler. Cas à couvrir explicitement : calcul
normal (readiness + conseil + VO2 présents), `readiness nil` → état vide
explicite (pas seulement implicite), `HealthStore(unavailable: ())` →
état « base indisponible » distinct sans lever d'erreur non gérée,
`weightAlert` toujours `nil` passé à `DailyAdviceEngine.advise(...)` (test
de non-régression sur le non-goal §2, pas juste une omission qu'un futur
lecteur pourrait « corriger » par erreur).

Convention du dépôt inchangée : tout test écrit pour attraper un bug
précis doit avoir été vu échouer contre ce bug ; pour de la logique
neuve, le cycle rouge (échec de compilation)/vert de TDD suffit.

Commande : `xcodebuild test -scheme HealthCheckCompanion -destination
'platform=iOS Simulator,name=<simulateur existant>'` — **sans**
`CODE_SIGNING_ALLOWED=NO` (convention du dépôt : le laisser non signé
prive l'app hôte du trousseau, et d'autres tests de cette cible en
dépendent).

## 10. Known limitations (accepted)

- **Fraîcheur dépendante du sync en arrière-plan.** iOS ne garantit aucun
  horaire pour `BackgroundSync` (`BackgroundSync.swift:9`, déjà documenté)
  — l'écran Conseils peut afficher des données de plusieurs heures si
  aucune synchro manuelle n'a eu lieu. Le tirer-pour-rafraîchir (§6) est le
  recours, comme pour le plan d'entraînement.
- **Pas de poids sur cet écran.** Décision confirmée (§2), pas une
  omission — un utilisateur qui consulte l'onglet Conseils sur iPhone
  n'y verra jamais de signal de poids, contrairement à l'écran Accueil du
  Mac. Le poids reste consultable sur l'écran Corps du Mac uniquement.
- **Pas de parité `BodyViewModel`.** Composition corporelle détaillée
  restera Mac-only tant que l'API Withings n'est pas relayée d'une façon
  ou d'une autre — non traité ici (§2).
- **Pas de vérification sur appareil physique dans ce sous-projet** —
  comme les sous-projets Companion précédents, la validation HealthKit
  réelle (autorisation, lecture, background delivery) reste manuelle,
  déléguée à Vincent après merge.
