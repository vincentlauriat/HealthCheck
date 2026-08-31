# HealthCheck — Conseiller poids (weight advisor)

**Décisions prises avec Vincent (2026-08-31) :** ceci est le sous-projet 3 de
la roadmap advisor/iPhone (sous-projet 0, fondation d'analyse partagée ;
sous-projet 1, conseiller VO2max/entraînement ; sous-projet 2, conseil du
jour transverse — tous mergés). Comme le sous-projet 2, aucun brouillon
n'existait pour celui-ci — le nom « weight advisor » ne venait que d'une
note d'intention dans l'en-tête de la spec du sous-projet 0. Ce document est
le résultat d'un brainstorming complet mené avec Vincent dans cette
conversation, section par section, chaque décision ci-dessous ayant été
approuvée explicitement avant d'être actée.

## 1. Context and motivation

`BodyCompositionEngine` assemble déjà les photographies journalières de
poids/composition et alimente l'écran Corps (dernière pesée, graphiques,
diagramme de répartition Sankey), mais c'est un moteur purement descriptif
— aucune interprétation. `InsightsEngine` porte un unique insight lié au
poids : un delta brut sur 30 jours (`inputs.weightDelta30d`, seuil ±1 kg),
neutre et symétrique, sans jugement sur le rythme ni mise en relation avec
l'entraînement. Aucune notion d'objectif de poids n'existe dans le code
(contrairement à `RaceGoal` pour la course).

Ce sous-projet ajoute deux choses : un moteur qui interprète le poids comme
un signal (rythme, direction, sécurité du rythme croisée avec la charge
d'entraînement — sur le même principe que `VO2MaxEngine.stagnationAlert(trend:chronicKm:)`,
qui reçoit déjà une métrique d'un autre moteur sans jamais l'appeler), et un
objectif de poids personnel (poids cible + date cible), calqué sur `RaceGoal`.
Contrairement au sous-projet 2 (pure composition de verdicts déjà
existants), il n'existe aujourd'hui aucun moteur qui produise un verdict sur
le poids — ce sous-projet en crée un, en s'appuyant sur les mêmes leçons que
`VO2MaxEngine` (fenêtres glissantes plutôt que delta premier/dernier point,
fragile aux valeurs isolées — la même correction que le sous-projet 1 avait
apportée à l'ancien insight VO2max).

Ce sous-projet s'appuie sur la fondation du sous-projet 0
(`HealthCheckShared/Analysis/`) et se câble dans le conseil du jour du
sous-projet 2 (`DailyAdviceEngine`) comme une troisième source d'alerte.

## 2. Goals / non-goals

**Goals :**
- Un nouveau moteur pur `WeightEngine` : tendance de poids (rythme,
  direction), trajectoire vers un objectif optionnel, alerte de sécurité de
  rythme (éventuellement durcie par la charge d'entraînement).
- Un nouveau modèle `WeightGoal` (poids cible + date cible), CRUD complet,
  stocké en base, calqué sur `RaceGoal`.
- UI sur l'écran Corps : carte de tendance (toujours visible si des données
  existent), carte d'objectif (création si aucun, trajectoire sinon).
- Câblage dans `DailyAdviceEngine` (sous-projet 2) comme 3e source
  d'alerte, ordre de scan déterministe étendu.

**Non-goals :**
- Pas de nouveau seuil physiologique pour l'entraînement — `trainingLoadElevated`
  réutilise une alerte déjà produite par `TrainingLoadMonitor.assess(...).alerts`,
  jamais un nouveau calcul de charge.
- Pas de scoring normé population — trajectoire et rythme se comparent
  uniquement à l'objectif personnel de l'utilisateur, jamais à une norme
  externe. Seule exception assumée et documentée : le repère de rythme sûr
  (§5) est une convention médicale usuelle, explicitement citée comme telle
  et non comme fait validé pour cette application — cohérent avec
  l'avertissement déjà présent en fin de `METHODOLOGY.md`.
- Pas d'UI Companion/iPhone dans ce sous-projet — seul le nouveau moteur va
  dans `HealthCheckShared/Analysis/` pour compiler côté iOS aussi, sans y
  être câblé.
- Un seul objectif de poids actif à la fois (comme les objectifs de
  course) — pas d'historique des objectifs passés affiché dans l'UI.
- Pas d'état dédié pour une date cible dépassée (« objectif en retard ») —
  `trajectory(...)` retourne `nil` dans ce cas plutôt qu'un nouveau verdict ;
  gérer cet état reste au choix de l'utilisateur (supprimer/recréer
  l'objectif), pas un nouveau comportement affiché.

## 3. Architecture overview

Nouveau moteur pur `HealthCheckShared/Analysis/WeightEngine.swift`, même
convention que les moteurs existants (`enum` de `static func`, `today`/
`calendar` en paramètres, aucune lecture d'horloge). Il ne dépend pas de
`BodyCompositionEngine` — il ne raisonne que sur la série de poids
(`[TrendPoint]`), pas sur la composition complète (graisse/masse
maigre/IMC), pour rester découplé de l'affichage Corps.

```
DashboardViewModel.loadWellness()
  ├── readiness, loadAssessment, vo2MaxAlert  [existants, sous-projet 2]
  ├── weightTrend = WeightEngine.trend(weights: weightDaily, ...)   [nouveau]
  ├── weightGoal = WeightGoal.active(in: try store.weightGoals(), ...) [nouveau]
  ├── weightSafetyAlert = WeightEngine.safetyAlert(
  │     trend: weightTrend,
  │     trainingLoadElevated: loadAssessment.alerts.contains { $0.severity == .warning }
  │   )   [nouveau]
  └── dailyAdvice = DailyAdviceEngine.advise(
        readiness:, loadAlerts:, vo2MaxAlert:, weightAlert: weightSafetyAlert
      )   [signature étendue]

BodyViewModel.load(period:)
  ├── snapshots  [existant, dépend de `period`]
  ├── weightGoal = WeightGoal.active(...)                              [nouveau]
  ├── weightTrend = WeightEngine.trend(weights: <28j indépendants de period>, ...) [nouveau]
  ├── weightTrajectory = WeightEngine.trajectory(trend:, goal:, ...)   [nouveau]
  └── weightSafetyAlert = WeightEngine.safetyAlert(...)                [nouveau, même formule]
```

Le calcul de `WeightTrend`/`safetyAlert` tourne indépendamment sur Accueil
et sur Corps (même principe que `VO2MaxTrend` déjà dupliqué entre
`DashboardViewModel` et `TrainingViewModel` depuis le sous-projet 1/2) — même
fenêtre, mêmes entrées, donc même résultat sur les deux écrans par
construction, pas par coïncidence.

## 4. Data model

```swift
struct WeightGoal: Equatable {
    let id: String
    let targetWeightKg: Double
    let targetDate: Date
    let createdAt: Date

    /// Objectif actif : le seul dont la date cible est encore future.
    /// Même sémantique que RaceGoal.active — le jour cible compte encore
    /// comme futur (comparaison au début du jour).
    static func active(in goals: [WeightGoal], today: Date,
                        calendar: Calendar = .current) -> WeightGoal? {
        let startOfToday = calendar.startOfDay(for: today)
        return goals
            .filter { calendar.startOfDay(for: $0.targetDate) >= startOfToday }
            .min { $0.targetDate < $1.targetDate }
    }
}

enum WeightDirection: Equatable { case losing, gaining, stable }

struct WeightTrend: Equatable {
    let recentAverageKg: Double   // moyenne des 14 derniers jours
    let priorAverageKg: Double    // moyenne des 14 jours juste avant
    let weeklyRateKg: Double      // (recentAverage - priorAverage) / 2 semaines, signé : positif = prise, négatif = perte
    let direction: WeightDirection
}

enum TrajectoryVerdict: Equatable { case onTrack, tooSlow, tooFast }

struct WeightTrajectory: Equatable {
    let verdict: TrajectoryVerdict
    let requiredWeeklyRateKg: Double
    let weeksRemaining: Double
}
```

## 5. WeightEngine (moteur pur)

```swift
enum WeightEngine {
    static let recentWindowDays = 14
    static let priorWindowDays = 14
    static let stableNoiseThresholdKg = 0.15
    static let onTrackToleranceRatio = 0.20   // ±20 % du rythme requis
    static let safeWarningRatePercent = 1.0   // % du poids corporel / semaine
    static let safeInfoRatePercent = 0.5

    static func trend(weights: [TrendPoint], today: Date, calendar: Calendar) -> WeightTrend? {
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today))!
        let recentStart = calendar.date(byAdding: .day, value: -recentWindowDays, to: endExclusive)!
        let priorStart = calendar.date(byAdding: .day, value: -(recentWindowDays + priorWindowDays),
                                       to: endExclusive)!

        let recentValues = weights.filter { $0.date >= recentStart && $0.date < endExclusive }.map(\.value)
        let priorValues = weights.filter { $0.date >= priorStart && $0.date < recentStart }.map(\.value)
        guard !recentValues.isEmpty, !priorValues.isEmpty else { return nil }

        let recentAverage = recentValues.reduce(0, +) / Double(recentValues.count)
        let priorAverage = priorValues.reduce(0, +) / Double(priorValues.count)
        let delta = recentAverage - priorAverage
        let weeklyRate = delta / 2.0  // 2 semaines entre les centres des deux fenêtres
        let direction: WeightDirection = abs(delta) < stableNoiseThresholdKg
            ? .stable : (delta > 0 ? .gaining : .losing)

        return WeightTrend(recentAverageKg: recentAverage, priorAverageKg: priorAverage,
                           weeklyRateKg: weeklyRate, direction: direction)
    }

    static func trajectory(trend: WeightTrend?, goal: WeightGoal?, today: Date,
                           calendar: Calendar) -> WeightTrajectory? {
        guard let trend, let goal else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                           to: calendar.startOfDay(for: goal.targetDate)).day ?? 0
        guard days > 0 else { return nil }
        let weeksRemaining = Double(days) / 7.0
        let requiredWeeklyRate = (goal.targetWeightKg - trend.recentAverageKg) / weeksRemaining

        guard abs(requiredWeeklyRate) > 0.01 else {
            return WeightTrajectory(verdict: .onTrack, requiredWeeklyRateKg: requiredWeeklyRate,
                                    weeksRemaining: weeksRemaining)
        }
        let ratio = trend.weeklyRateKg / requiredWeeklyRate
        let verdict: TrajectoryVerdict
        if ratio < 1 - onTrackToleranceRatio {
            verdict = .tooSlow
        } else if ratio > 1 + onTrackToleranceRatio {
            verdict = .tooFast
        } else {
            verdict = .onTrack
        }
        return WeightTrajectory(verdict: verdict, requiredWeeklyRateKg: requiredWeeklyRate,
                                weeksRemaining: weeksRemaining)
    }

    static func safetyAlert(trend: WeightTrend?, trainingLoadElevated: Bool) -> LoadAlert? {
        guard let trend, trend.recentAverageKg > 0 else { return nil }
        let ratePercent = abs(trend.weeklyRateKg) / trend.recentAverageKg * 100
        if ratePercent >= safeWarningRatePercent {
            let base = "Rythme de variation du poids au-dessus du repère usuel (≈1 %/semaine)."
            let message = trainingLoadElevated
                ? base + " Combiné à une charge d'entraînement élevée, veillez à un apport énergétique suffisant."
                : base
            return LoadAlert(severity: .warning, message: message)
        }
        if ratePercent >= safeInfoRatePercent {
            return LoadAlert(severity: .info, message: "Rythme de variation du poids notable — à surveiller.")
        }
        return nil
    }
}
```

`ratio < 1 - tolérance` couvre aussi le cas d'un rythme de signe opposé au
rythme requis (ratio négatif) — s'éloigner de l'objectif est bien un cas de
`.tooSlow` (le rythme nécessaire n'est pas atteint), pas un cas séparé.

## 6. Storage

```swift
func saveWeightGoal(_ goal: WeightGoal) throws
func deleteWeightGoal(id: String) throws
func weightGoals() throws -> [WeightGoal]
```

Nouvelle table, même schéma `CREATE TABLE IF NOT EXISTS` que `race_goal` :

```sql
CREATE TABLE IF NOT EXISTS weight_goal (
    id TEXT PRIMARY KEY,
    targetWeightKg REAL NOT NULL,
    targetDate TEXT NOT NULL,
    createdAt TEXT NOT NULL
)
```

## 7. DailyAdviceEngine changes (sous-projet 2)

`advise(...)` gagne un 3e paramètre optionnel :

```swift
static func advise(
    readiness: ReadinessScore?,
    loadAlerts: [LoadAlert],
    vo2MaxAlert: LoadAlert?,
    weightAlert: LoadAlert?
) -> DailyAdvice?
```

Ordre de scan déterministe étendu : `loadAlerts` → `vo2MaxAlert` →
`weightAlert` (ajouté en dernier, l'ordre existant entre charge et VO2max
ne change pas). Le reste de la logique (palier dérivé de `readiness.label`,
substitution interdite sous `.opportunite`) est inchangé.

**Changement atomique de compilation :** comme `SessionKind`/`InsightInputs`
au sous-projet 1, toute tâche qui modifie cette signature met à jour tous
les points d'appel (`DashboardViewModel.swift`) dans le même commit.

## 8. DashboardViewModel / BodyViewModel wiring

`DashboardViewModel.loadWellness()` réutilise `weightDaily` (déjà chargé,
fenêtre de 30 jours — suffisant pour les fenêtres 14+14 du moteur) pour
calculer `weightTrend`, charge l'objectif actif via `store.weightGoals()`,
et calcule `weightSafetyAlert` en réutilisant `loadAssessment.alerts` (déjà
calculé au sous-projet 2) pour `trainingLoadElevated` — aucun second appel à
`TrainingLoadMonitor`.

`BodyViewModel.load(period:)` calcule les mêmes `weightTrend`/`weightGoal`/
`weightSafetyAlert` à partir d'une fenêtre de 28 jours **indépendante** du
sélecteur de période (comme `weightDelta30d` aujourd'hui) — jamais à partir
de `snapshots`, qui varie avec la période choisie et peut ne couvrir que
quelques jours. `weightTrajectory` est propre à `BodyViewModel` (Accueil
n'affiche pas de trajectoire, seulement l'alerte de sécurité).

**Précision (2026-08-31) :** `BodyViewModel` n'a aujourd'hui aucun accès à
un `LoadAssessment` — contrairement à `DashboardViewModel`, qui en calcule
un depuis le sous-projet 2 — et cette tâche ne lui en donne pas un
(dupliquer le chargement d'historique juste pour cette nuance serait
disproportionné). L'appel de `BodyViewModel` à `WeightEngine.safetyAlert(...)`
passe donc toujours `trainingLoadElevated: false` : le message durci par la
charge d'entraînement n'apparaît que sur Accueil, où ce contexte existe déjà
nativement — cohérent avec le sous-projet 2, où la composition de signaux
croisés est justement la responsabilité de `DashboardViewModel`/`DailyAdviceEngine`,
pas de chaque écran individuel.

## 9. UI — écran Corps

Deux nouvelles cartes dans `BodyView.swift`, entre le bloc existant
(dernière pesée / métriques / Sankey) et le sélecteur de période :

- **Carte « Tendance »** : toujours affichée si `weightTrend != nil` —
  rythme (kg/semaine), direction, alerte de sécurité le cas échéant
  (`Label` orange/gris, même style que `TrainingView.loadSection`).
- **Carte « Objectif »** : sans objectif actif, un bouton « Définir un
  objectif » ouvre un formulaire (poids cible + date cible), calqué sur
  `TrainingView.createGoalForm`. Avec objectif actif : verdict de
  trajectoire, rythme requis vs réel, semaines restantes, bouton de
  suppression.

## 10. Error handling

- Fenêtre récente ou antérieure sans aucune pesée → `trend` `nil`, pas de
  valeur de repli inventée (même principe que `VO2MaxEngine.trend`).
- Aucun objectif actif → `trajectory` `nil`, l'UI affiche le formulaire de
  création plutôt qu'une trajectoire vide.
- Date cible dépassée (`days <= 0`) → `trajectory` `nil` (non-goal §2, pas
  de nouvel état affiché).
- `recentAverageKg == 0` (donnée invalide) → `safetyAlert` `nil` plutôt
  qu'une division par zéro.
- Toutes les nouvelles méthodes `HealthStore` propagent leurs erreurs
  (`throws`), jamais de `try?` silencieux, cohérent avec la convention du
  dépôt.

## 11. Code structure

- Create: `HealthCheckShared/Analysis/WeightEngine.swift`
- Create: `HealthCheckShared/Models/WeightGoal.swift`
- Modify: `HealthCheckShared/Store/HealthStore.swift` (table `weight_goal`
  + 3 méthodes)
- Modify: `HealthCheckShared/Analysis/DailyAdviceEngine.swift` (signature
  `advise(...)` + ordre de scan)
- Modify: `HealthCheck/ViewModels/DashboardViewModel.swift` (câblage
  `weightTrend`/`weightSafetyAlert`, appel `advise(...)` mis à jour)
- Modify: `HealthCheck/ViewModels/BodyViewModel.swift` (câblage
  `weightGoal`/`weightTrend`/`weightTrajectory`/`weightSafetyAlert`,
  méthodes de création/suppression d'objectif)
- Modify: `HealthCheck/Views/BodyView.swift` (cartes Tendance/Objectif,
  formulaire de création)
- Modify: `docs/METHODOLOGY.md` (nouvelle section `WeightEngine`)

Aucun fichier de `Companion/` ou `CompanionTests/` n'est touché.

## 12. Testing strategy

Convention du dépôt : toute garde de non-régression doit avoir été vue
échouer contre le bug qu'elle prétend attraper (le cycle rouge/vert du TDD
suffit pour de la logique neuve, comme aux sous-projets 1 et 2).

Pour `WeightEngine` :
- `trend` : fenêtre récente/antérieure vide → `nil` (x2, une par fenêtre) ;
  direction `.losing`/`.gaining`/`.stable` avec un cas à la frontière du
  seuil de bruit (0,15 kg) de chaque côté ; rythme hebdomadaire calculé
  correctement à partir du delta.
- `trajectory` : `.onTrack` (dans la tolérance ±20 %, aux deux bornes),
  `.tooSlow` (en dessous, y compris rythme de signe opposé), `.tooFast`
  (au-dessus) ; `nil` sans objectif ; `nil` si la date cible est dépassée ;
  cas `requiredWeeklyRateKg` proche de zéro (déjà à l'objectif).
- `safetyAlert` : aucune alerte sous 0,5 %/semaine, `.info` entre 0,5 % et
  1 %, `.warning` au-dessus, message durci quand `trainingLoadElevated`.
- `WeightGoal.active` : sélectionne la date cible future la plus proche,
  ignore les dates passées, `nil` sans objectif — même forme de tests que
  `RaceGoal.active` déjà dans le dépôt.

Pour le câblage `DailyAdviceEngine` : un test avec les 3 sources d'alerte
simultanément `.warning`, vérifiant que `loadAlerts` l'emporte toujours
(ordre inchangé), et un test avec seulement `weightAlert` en `.warning`
pour vérifier qu'il remonte bien en dernier recours.

Pour le câblage `DashboardViewModel`/`BodyViewModel` : extension des
fichiers de tests existants (pas de nouvelle garde dédiée), sur le modèle
du test de câblage du sous-projet 2 — un scénario qui pose un historique de
poids concret et vérifie le résultat composé, pas un simple « ça ne
plante pas ».

## 13. Known limitations (accepted)

- Le repère de rythme sûr (1 %/semaine) est une convention médicale
  usuelle appliquée uniformément, pas ajustée à la morphologie ou à l'état
  de santé de l'utilisateur — assumé, documenté dans `METHODOLOGY.md` avec
  la réserve déjà en place en fin de document.
- `WeightEngine.trend` et `BodyCompositionEngine` calculent tous deux à
  partir de séries de poids mais restent des moteurs séparés et ne
  partagent aucune fonction — accepté pour garder chacun à responsabilité
  unique (interprétation de signal vs. composition/affichage), plutôt que
  de coupler artificiellement les deux.
