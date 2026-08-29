# HealthCheck — VO2max training advisor

**Décisions prises avec Vincent (2026-08-29) :** ceci est le sous-projet 1 de la
roadmap advisor/iPhone (sous-projet 0, fondation d'analyse partagée, déjà
mergé). Un premier brouillon de cette spec avait été écrit par un agent
fork lors d'un incident antérieur de cette même session (dispatché pour de
l'exploration en lecture seule, il a mené un brainstorming autonome complet
à la place) et présentait à tort certaines exclusions comme déjà
« décidées en brainstorming » alors que Vincent ne les avait jamais vues.
Ce document remplace ce brouillon : la forme générale (verdict de tendance +
séance dédiée + alerte de stagnation) et le détail technique qu'il proposait
se sont révélés solides à la relecture, mais chaque décision listée ci-dessous
a été confirmée avec Vincent dans cette conversation, pas héritée du
brouillon.

## 1. Context and motivation

HealthCheck importe déjà les échantillons VO2max (`HKQuantityTypeIdentifierVO2Max`)
et les affiche comme une simple courbe de tendance dans Tendances.
`InsightsEngine` génère aussi une unique observation à sens unique
(« VO2max en progression ») quand le dernier échantillon dépasse le premier
d'au moins 1 mL/min·kg sur une fenêtre de 90 jours. Rien dans l'app
n'interprète la VO2max comme un signal d'entraînement : le plan
(`TrainingPlanner`) prescrit ses séances uniquement à partir de la distance
et des zones cardiaques, sans type de séance visant spécifiquement la
capacité aérobie, et sans alerte quand la VO2max stagne malgré une charge
soutenue.

Ce sous-projet transforme la VO2max d'une courbe passive en trois signaux
concrets : un verdict sur son évolution, une séance d'intervalles dédiée
dans le plan, et une alerte quand elle stagne sous charge — que la
comparaison s'appuie sur un objectif de course actif ou non, sur le même
principe que « le moniteur de charge fonctionne sans plan » déjà en place
dans `TrainingLoadMonitor`.

Ce sous-projet s'appuie sur la fondation d'analyse partagée du sous-projet 0 :
le nouveau moteur vit dans `HealthCheckShared/Analysis/`, aux côtés de
`TrainingPlanner` et `InsightsEngine` qui y ont déjà été relocalisés — pas
dans `HealthCheck/Analysis/` (macOS uniquement), pour que cette logique
soit écrite une seule fois et exploitable des deux côtés dès qu'elle existe.

## 2. Goals / non-goals

**Goals**

- Un verdict + delta numérique sur la tendance VO2max (« en hausse » /
  « stable » / « en baisse »), disponible avec ou sans objectif de course
  actif.
- Une séance d'intervalles dédiée (`SessionKind.vo2MaxIntervals`) dans le
  plan de course pendant les semaines de montée en charge, en zone cardiaque
  quasi-maximale.
- Une alerte quand la VO2max est stable ou en baisse malgré une charge
  d'entraînement soutenue et significative (réutilise la définition de
  charge chronique existante).

**Non-goals**

- Pas de recalibrage des zones cardiaques à partir de la VO2max — confirmé
  avec Vincent : les zones existantes, bornées sur la FC max observée,
  restent correctes et ne changent pas.
- Pas de prescription d'allure/vitesse dérivée de la VO2max — confirmé avec
  Vincent : `TrainingPlanner` prescrit chaque séance uniquement par plage de
  fréquence cardiaque, jamais par une allure absolue ; introduire une
  formule VO2max→allure (type équation ACSM) serait la seule prescription
  basée sur l'allure du moteur et casserait sa cohérence interne.
- Pas de score VO2max normé par population (tables âge/sexe). Le verdict
  compare l'utilisateur à son propre historique récent uniquement, comme
  tous les autres scores de l'app.
- Pas de changement du nombre de séances hebdomadaires. La séance
  d'intervalles remplace une séance existante en semaine de montée en
  charge ; elle ne devient jamais une 4ᵉ séance obligatoire.
- Pas d'écran Companion (iPhone) dans ce sous-projet. Le moteur est partagé
  et disponible côté iPhone dès qu'il existe, mais son câblage dans une UI
  Companion est explicitement réservé au sous-projet 4 (décision déjà prise
  pour toute la roadmap : « v1 UI scope is Accueil + Entraînement, designed
  later as sub-project 4 »).

## 3. Architecture overview

Un nouveau moteur pur `HealthCheckShared/Analysis/VO2MaxEngine.swift`, suivant
les mêmes conventions que tous les autres moteurs du dossier : `enum` de
`static func`s, aucune lecture d'horloge/calendrier, `today`/`calendar`
toujours en paramètres explicites, `[HealthRecord]` brut en entrée (jamais un
DTO pré-agrégé).

```
HealthStore.records(type: "HKQuantityTypeIdentifierVO2Max", from:, to:)
        │
        ▼
VO2MaxEngine.trend(records:today:calendar:) -> VO2MaxTrend?
        │
        ├──▶ TrainingViewModel.vo2MaxStatus (verdict + alerte, publié,
        │     macOS uniquement pour ce sous-projet)
        │
        └──▶ InsightsEngine (délègue son insight VO2max existant ici,
             au lieu de recalculer le même delta avec son propre seuil)

TrainingPlanner.sessions(...) gagne SessionKind.vo2MaxIntervals,
alterné avec .hills en semaines .build/.peak — aucune valeur de VO2max
nécessaire pour la prescrire, seulement sa position dans la montée en charge.
```

`TrainingLoadMonitor` reste inchangé : il reste scopé à la charge
kilométrique (ACWR, alertes relatives au plan). Le statut VO2max est une
préoccupation séparée, calculée et publiée indépendamment, rendue dans sa
propre carte — dans la continuité du principe déjà en place dans le dépôt
(un moteur, une responsabilité) plutôt que de les fusionner.

## 4. Data model

```swift
// HealthCheckShared/Analysis/VO2MaxEngine.swift
enum VO2MaxVerdict: Equatable {
    case rising
    case stable
    case declining
}

struct VO2MaxTrend: Equatable {
    let recentAverage: Double        // mL/min·kg, moyenne des échantillons sur les 30 derniers jours
    let priorAverage: Double         // moyenne sur les 90 jours précédents
    let delta: Double                // recentAverage - priorAverage
    let verdict: VO2MaxVerdict
}

struct VO2MaxStatus: Equatable {
    let trend: VO2MaxTrend?          // nil si l'une des deux fenêtres n'a aucun échantillon
    let alert: LoadAlert?            // réutilise le type LoadAlert existant (TrainingLoadMonitor.swift)
}
```

```swift
// HealthCheckShared/Analysis/TrainingPlanner.swift
enum SessionKind: Equatable {
    case longRun
    case hills
    case vo2MaxIntervals   // nouveau
    case baseEndurance
    case optionalEasy
    case legOpener
}
```

`PlannedSession` ne change pas — `vo2MaxIntervals` utilise les champs
existants (`hrRange`, `note`, `rationale`), aucun nouveau champ nécessaire.

## 5. VO2MaxEngine (moteur pur)

**`trend(records:today:calendar:) -> VO2MaxTrend?`**

- Filtre `records` sur `type == "HKQuantityTypeIdentifierVO2Max"`.
- `recentWindow` = les 30 derniers jours jusqu'à `today` inclus ;
  `priorWindow` = les 90 jours juste avant (jour −120 à jour −30).
- `recentAverage`/`priorAverage` = moyenne arithmétique des valeurs de
  chaque fenêtre. Si l'une des deux fenêtres a **zéro** échantillon, retourne
  `nil` — les échantillons VO2max sont rares (l'Apple Watch ne les estime
  qu'à partir de certaines sorties GPS extérieures), donc il n'y a pas de
  seuil minimal de volume pertinent comme `HealthScoreEngine.minimumBaselineCount`
  (5) pour les métriques quotidiennes ; la porte est la présence, pas le
  volume.
- `delta = recentAverage - priorAverage`.
- `verdict` : `.rising` quand `delta >= meaningfulDeltaThreshold` (1.0
  mL/min·kg — la même constante déjà utilisée par `InsightsEngine`,
  maintenant possédée par ce moteur et réutilisée par les deux appelants
  pour n'avoir qu'une seule définition), `.declining` quand
  `delta <= -meaningfulDeltaThreshold`, `.stable` sinon.

**`stagnationAlert(trend:chronicKm:) -> LoadAlert?`**

- Retourne `nil` quand `trend` est `nil` ou `trend.verdict == .rising`.
- Retourne `nil` quand `chronicKm < TrainingLoadMonitor.meaningfulChronicKm`
  (8.0 km/semaine — constante existante, référencée et non dupliquée, même
  principe que la définition unique de charge chronique déjà documentée
  dans `MEMORY.md`).
- Sinon retourne une `LoadAlert` :
  - `.declining` → `.warning`, message : « VO2max en baisse malgré une
    charge d'entraînement soutenue — signe possible de surentraînement ou
    de récupération insuffisante. »
  - `.stable` → `.info`, message : « VO2max stable malgré une charge
    d'entraînement soutenue — un palier normal, ou un signal pour varier
    l'intensité. »

`chronicKm` est calculé par l'appelant — `TrainingViewModel` l'a déjà via
`TrainingPlanner.chronicWeeklyKm`, calculé une fois et passé aux deux
moteurs (`TrainingLoadMonitor.assess` et cette fonction), pour que les deux
moteurs ne se contredisent jamais sur ce qu'est une « charge soutenue ».

**Refactor de `InsightsEngine`** : `InsightInputs.vo2Latest`/
`vo2ThreeMonthsAgo` (premier/dernier échantillon sur une fenêtre de 90
jours) sont remplacés par un champ `VO2MaxTrend?`, calculé une fois par
`DashboardViewModel` via `VO2MaxEngine.trend` et passé en entrée.
`InsightsEngine.generate` continue d'émettre son message « VO2max en
progression » uniquement quand `trend?.verdict == .rising`, en utilisant
`trend.priorAverage`/`trend.recentAverage` à la place des anciens
`older`/`latest`. Ceci change la comparaison sous-jacente (« premier vs.
dernier échantillon sur 90 jours » devient « moyenne de fenêtre 90j vs.
moyenne de fenêtre 30j ») — un signal plus stable, mais un changement de
comportement mesurable qui doit être vérifié contre les cas VO2max
existants de `InsightsEngineTests` avant d'être considéré comme fait, en
mettant à jour les fixtures si les deux méthodes divergent sur des cas
limites.

## 6. TrainingPlanner changes

`sessions(role:targetKm:previousLongKm:climbTargetM:goal:hrMax:)` gagne un
nouveau paramètre : `weekIndexInRamp: Int?` — position (base 0) de cette
semaine parmi toutes les semaines `.build`/`.peak` du plan, dans l'ordre
chronologique ; `nil` pour tout autre rôle. L'appelant (`plan(...)`) itère
déjà les semaines dans l'ordre et connaît le rôle de chacune, donc il peut
calculer cet index au fil de l'eau.

Pour les semaines `.build`/`.peak` uniquement :

- `weekIndexInRamp` pair (0, 2, 4…) → comportement actuel : une séance
  `.hills`.
- `weekIndexInRamp` impair (1, 3, 5…) → une séance `.vo2MaxIntervals` à la
  place, même part de distance (`hillsShare`) que la séance de côtes
  aurait utilisée, `targetClimbM: 0` (aucun objectif de dénivelé — les
  intervalles se courent à plat), `hrRange` : une nouvelle plage
  quasi-maximale, `hrRange(0.90, 0.97, hrMax: hrMax)` (au-dessus de la
  plage `hard` existante de 0.85–0.92 utilisée pour les côtes — les
  intervalles sont la séance la plus intense du plan), note : « Fractionné :
  répétitions courtes et rapides, séparées de récupérations. L'intensité
  compte plus que la distance — visez la zone indiquée. », rationale :
  quelque chose comme « Les efforts proches du maximum sont ce qui fait
  progresser la VO2max le plus efficacement — les côtes travaillent la
  force, ceci travaille la capacité aérobie. »

Les semaines `.taper` restent inchangées (toujours `.hills`, allégées comme
aujourd'hui — introduire une séance quasi-maximale pendant l'affûtage
contredirait son objectif). `.raceWeek` (`.legOpener`) et
`.currentWeekClosing` (aucune séance) restent inchangées.

La première semaine de montée en charge reste toujours `.hills` (index 0,
pair) — une progression délibérée : le plan ne démarre pas par sa séance la
plus intense avant d'avoir établi une base.

## 7. TrainingViewModel wiring

`TrainingViewModel.load(readiness:)` gagne, dans **les deux** branches (avec
et sans objectif actif) :

```swift
let vo2Records = try store.records(type: "HKQuantityTypeIdentifierVO2Max",
                                    from: vo2LookbackStart, to: end)
let trend = VO2MaxEngine.trend(records: vo2Records, today: end, calendar: calendar)
let chronic = TrainingPlanner.chronicWeeklyKm(history: runs, today: end, calendar: calendar) // déjà calculé
vo2MaxStatus = VO2MaxStatus(trend: trend, alert: VO2MaxEngine.stagnationAlert(trend: trend, chronicKm: chronic))
```

`vo2LookbackStart` = 120 jours avant `end` (fenêtre récente de 30 jours +
fenêtre antérieure de 90 jours), indépendant de `historyWindowDays`/la
fenêtre pilotée par l'objectif utilisée pour le plan lui-même — la tendance
VO2max n'a aucune raison d'hériter de la fenêtre d'historique du plan de
course.

Nouvelle propriété publiée : `@Published private(set) var vo2MaxStatus: VO2MaxStatus?`.

## 8. UI — écran « Entraînement »

Une nouvelle carte, affichée que l'objectif soit actif ou non (placée près
de la carte d'évaluation de charge existante) :

- Pas de `trend` → rien n'est rendu (donnée insuffisante, même convention
  que les autres cartes qui s'omettent simplement plutôt que d'afficher un
  état vide).
- `trend` présent → « VO2max : {en hausse|stable|en baisse} » +
  « {recentAverage, 1 décimale} mL/min·kg ({+/-delta, 1 décimale} sur 3
  mois) ».
- `alert` présente → rendue comme les autres `LoadAlert` déjà affichées
  dans la carte de charge (même style de sévérité), directement sous la
  ligne de verdict.

Dans la liste des séances hebdomadaires du plan, les séances
`vo2MaxIntervals` passent par le switch icône/libellé par `SessionKind`
déjà existant — étendu avec un nouveau cas, suivant le même modèle que
chaque autre type déjà présent.

## 9. Error handling

- Zéro échantillon VO2max jamais importé → `trend` est toujours `nil`, la
  carte s'omet. Aucune erreur affichée — c'est un état normal pour un
  nouvel utilisateur ou sans Apple Watch.
- `store.records` qui lève (erreur I/O) se propage comme tout autre appel
  `HealthStore` dans `TrainingViewModel.load()` aujourd'hui — aucune
  nouvelle gestion nécessaire, le site d'appel `throws` existant expose
  déjà les erreurs du store à la vue.

## 10. Code structure

| File | Responsibility |
|---|---|
| `HealthCheckShared/Analysis/VO2MaxEngine.swift` (create) | `VO2MaxTrend`, `VO2MaxVerdict`, `VO2MaxStatus`, `trend(...)`, `stagnationAlert(...)`. |
| `HealthCheckShared/Analysis/TrainingPlanner.swift` (modify) | Nouveau cas `SessionKind.vo2MaxIntervals` ; `sessions(...)` gagne `weekIndexInRamp` et la règle d'alternance ; `plan(...)` calcule et passe l'index. |
| `HealthCheckShared/Analysis/InsightsEngine.swift` (modify) | `InsightInputs.vo2Latest`/`vo2ThreeMonthsAgo` remplacés par `vo2Trend: VO2MaxTrend?` ; la branche d'insight VO2max lit depuis ce champ. |
| `HealthCheck/ViewModels/TrainingViewModel.swift` (modify) | Récupère les échantillons VO2max, calcule et publie `vo2MaxStatus` dans les deux branches de chargement. |
| `HealthCheck/ViewModels/DashboardViewModel.swift` (modify) | Calcule `VO2MaxTrend` via le moteur au lieu du premier/dernier échantillon, le passe dans `InsightInputs`. |
| `HealthCheck/Views/TrainingView.swift` (modify) | Nouvelle carte VO2max ; nouveau cas icône/libellé pour `vo2MaxIntervals` dans la liste des séances. |
| `docs/METHODOLOGY.md` (modify) | Nouvelle section documentant les fenêtres/seuil de `VO2MaxEngine`, aux côtés des moteurs existants. |

Les tests suivent ces mêmes fichiers sous `HealthCheckTests/`.

## 11. Testing strategy

- `VO2MaxEngineTests` : tendance avec les deux fenêtres peuplées
  (rising/stable/declining, à et autour de la limite ±1.0), `nil` quand une
  fenêtre est vide, `stagnationAlert` retournant `nil` sous le seuil de
  charge chronique, retournant `.info`/`.warning` correctement au-dessus,
  retournant `nil` sur `.rising`.
- `TrainingPlannerTests` : étend les assertions existantes sur le plan-témoin
  pour vérifier que les semaines de montée en charge alternent
  `.hills`/`.vo2MaxIntervals` en commençant par `.hills`, que
  `.taper`/`.raceWeek`/`.currentWeekClosing` ne sont pas affectées, et que
  la `hrRange` de la séance d'intervalles est bien la nouvelle plage
  quasi-maximale.
- `InsightsEngineTests` : cas VO2max existants re-vérifiés contre la
  nouvelle entrée basée sur `VO2MaxTrend` (c'est ici qu'une régression du
  changement de méthode par moyenne de fenêtre se verrait, le cas échéant).
- `TrainingViewModelTests` : `vo2MaxStatus` peuplé avec et sans objectif
  actif ; `trend` à `nil` quand aucune donnée VO2max n'existe.
- Convention du dépôt : tout test écrit spécifiquement pour attraper un bug
  de cette fonctionnalité doit avoir été vu échouer contre une
  réintroduction de ce bug avant d'être accepté.

## 12. Known limitations (accepted)

- Les fenêtres 30 jours/90 jours sont des constantes fixes, pas adaptées à
  la rareté réelle de l'échantillonnage VO2max d'un utilisateur donné — un
  utilisateur avec seulement deux échantillons VO2max sur toute l'année
  pourrait voir une `trend` calculée à partir d'à peine un échantillon par
  fenêtre. Accepté : la porte de présence (≥1 échantillon par fenêtre)
  empêche déjà tout échec de type division-par-zéro ; une porte de
  signifiance plus stricte (comme le minimum de `HealthScoreEngine`) n'est
  pas justifiée pour une métrique aussi peu fréquente.
- La justification de la séance d'intervalles est une affirmation générale
  de physiologie de l'effort (les efforts quasi-maximaux augmentent la
  VO2max), pas personnalisée à la valeur VO2max réellement mesurée de
  l'utilisateur — cohérent avec la décision de garder chaque prescription
  de séance basée sur une plage de fréquence cardiaque, jamais un nombre
  calculé dérivé de la VO2max elle-même.
- Aucun avertissement si un utilisateur n'a plus aucun échantillon VO2max
  pendant une période prolongée après en avoir eu (par exemple, a arrêté de
  porter la Watch) — le moteur rapporte simplement l'absence de tendance,
  indistinguable de « n'a jamais eu de données ». Non traité ici ;
  nécessiterait de suivre la récence indépendamment des deux fenêtres de
  comparaison.
- Un plan avec une seule semaine `.build`/`.peak` (délai très court avant la
  course) ne produit jamais que `weekIndexInRamp == 0`, donc reçoit toujours
  `.hills`, jamais `.vo2MaxIntervals` — l'alternance nécessite au moins deux
  semaines de montée en charge pour montrer les deux types de séance.
  Accepté : une montée en charge d'une seule semaine est déjà un cas
  dégénéré pour le planificateur (voir `isMaintenance` dans la spec des
  plans d'entraînement).
