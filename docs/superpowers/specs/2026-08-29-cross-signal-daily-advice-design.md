# HealthCheck — Conseil du jour transverse (cross-signal daily advice)

**Décisions prises avec Vincent (2026-08-29) :** ceci est le sous-projet 2 de
la roadmap advisor/iPhone (sous-projet 0, fondation d'analyse partagée, et
sous-projet 1, conseiller VO2max/entraînement, déjà mergés). Contrairement
au sous-projet 1, aucun brouillon n'existait pour celui-ci — le nom
« conseils transverses quotidiens » ne venait que d'une note d'intention
dans l'en-tête de la spec du sous-projet 0, sans périmètre défini. Ce
document est le résultat d'un brainstorming complet mené avec Vincent dans
cette conversation, section par section, chaque décision ci-dessous ayant
été approuvée explicitement avant d'être actée.

## 1. Context and motivation

`InsightsEngine` génère déjà des observations en langage naturel à partir
d'agrégats pré-calculés (FC repos, sommeil, pas, VO2max, poids), mais
chaque signal y est traité indépendamment — aucune corrélation entre eux.
`HealthScoreEngine.readiness(...)` agrège sommeil/FC repos/HRV/activité en
un score de forme unique (`ReadinessScore.value` + `.label`), affiché sur
l'écran Accueil. `TrainingLoadMonitor.assess(...)` et
`VO2MaxEngine.stagnationAlert(...)` produisent chacun des `LoadAlert`
(charge d'entraînement, stagnation VO2max), mais ces alertes ne sont
aujourd'hui visibles que sur l'écran Entraînement — l'Accueil ne les voit
jamais.

Ce sous-projet ajoute une carte « Conseil du jour » sur l'Accueil qui relie
ces signaux déjà calculés en un message unique et priorisé, sans introduire
de nouveau seuil physiologique ni de nouveau calcul indépendant. C'est
délibérément une **composition** de verdicts déjà produits et déjà
documentés (`METHODOLOGY.md`), pas une nouvelle couche de règles sur des
métriques brutes — ce choix a été discuté explicitement avec Vincent
(approches A/B) et l'approche A (agrégateur fin) a été retenue.

`CorrelationEngine.swift` (coefficient de Pearson pour les nuages de
points de l'écran Tendances) a été examiné et écarté : c'est un outil de
visualisation statistique, pas un moteur de conseil, sans rapport avec ce
sous-projet.

## 2. Goals / non-goals

**Goals :**
- Une carte « Conseil du jour » sur l'écran Accueil (macOS), affichant un
  message priorisé unique dérivé du score de forme (`readiness`) du jour.
- Le message ne peut jamais contredire le label de `readiness` déjà affiché
  juste au-dessus (ex. jamais « bon moment pour une séance clé » alors que
  le label dit « Récupération conseillée »).
- Le texte peut être affiné par une alerte `.warning` existante
  (`TrainingLoadMonitor`/`VO2MaxEngine`) quand elle est compatible avec le
  palier du jour.
- Sélection déterministe : mêmes entrées → même conseil, toujours.

**Non-goals :**
- Pas de nouveau seuil physiologique inventé — tout seuil utilisé existe
  déjà et est déjà documenté dans `METHODOLOGY.md` pour son moteur d'origine.
- Pas de scoring normé population — comme tous les moteurs de ce dépôt, la
  comparaison reste au score de forme et aux alertes déjà personnalisés de
  l'utilisateur, jamais à une norme externe.
- Pas d'UI Companion/iPhone dans ce sous-projet (sous-projet 4 de la
  roadmap) — seul le nouveau moteur va dans `HealthCheckShared/Analysis/`
  pour compiler côté iOS aussi, sans y être câblé.
- Ne remplace pas la liste `insights` existante (`InsightsEngine`) —
  coexiste avec elle, à un autre endroit de l'écran.
- Pas de recalcul indépendant des alertes `.info` de `TrainingLoadMonitor`
  (déjà visibles sur Entraînement) — pour ne pas les dupliquer, seules les
  alertes `.warning` peuvent remonter dans ce conseil.

## 3. Architecture overview

Nouveau moteur pur `HealthCheckShared/Analysis/DailyAdviceEngine.swift`,
même convention que les 11 moteurs existants : `enum` de `static func`,
sans état, `today`/`calendar` en paramètres quand nécessaire (ici, aucune
horloge n'est requise — l'entrée est déjà résolue en verdicts du jour par
l'appelant).

Le moteur ne lit aucune donnée brute. Il reçoit en entrée les sorties déjà
calculées par trois moteurs existants :
- `ReadinessScore?` (`HealthScoreEngine.readiness(...)`)
- `[LoadAlert]` (`TrainingLoadMonitor.assess(...).alerts`)
- `LoadAlert?` (`VO2MaxEngine.stagnationAlert(...)`, via `VO2MaxStatus.alert`)

et retourne un unique `DailyAdvice?` — `nil` quand `readiness` est `nil`.

```
DashboardViewModel.loadWellness()
  ├── readiness = HealthScoreEngine.readiness(...)        [existant]
  ├── loadAssessment = TrainingLoadMonitor.assess(plan: nil, ...) [nouveau câblage — voir §6]
  ├── vo2Status = VO2MaxStatus(trend:, stagnationAlert:)   [nouveau câblage]
  └── dailyAdvice = DailyAdviceEngine.advise(
        readiness: readiness,
        loadAlerts: loadAssessment.alerts,
        vo2MaxAlert: vo2Status.alert
      )
```

## 4. Data model

```swift
enum AdviceTier: Equatable {
    case repos          // readiness.label == "Récupération conseillée"
    case prudence        // readiness.label == "Forme correcte"
    case opportunite      // readiness.label == "Bonne forme" ou "Excellente forme"
}

struct DailyAdvice: Equatable {
    let tier: AdviceTier
    let message: String
}
```

`message` est soit le texte d'une `LoadAlert.message` existante (citée
verbatim, pas reformulée), soit un texte générique fixe par palier — voir
§5.

## 5. DailyAdviceEngine (moteur pur)

```swift
enum DailyAdviceEngine {
    static func advise(
        readiness: ReadinessScore?,
        loadAlerts: [LoadAlert],
        vo2MaxAlert: LoadAlert?
    ) -> DailyAdvice? {
        guard let readiness else { return nil }
        let tier = self.tier(for: readiness.label)

        // Une alerte .warning ne peut affiner le conseil que sous REPOS ou
        // PRUDENCE — jamais sous OPPORTUNITÉ, où elle contredirait le
        // label déjà affiché. Ordre de scan fixe et déterministe :
        // d'abord les alertes de charge (dans leur ordre de production),
        // puis celle de VO2max.
        if tier != .opportunite,
           let warning = (loadAlerts + [vo2MaxAlert].compactMap { $0 })
               .first(where: { $0.severity == .warning }) {
            return DailyAdvice(tier: tier, message: warning.message)
        }

        return DailyAdvice(tier: tier, message: genericMessage(for: tier))
    }

    private static func tier(for label: String) -> AdviceTier {
        switch label {
        case "Récupération conseillée": return .repos
        case "Forme correcte": return .prudence
        default: return .opportunite // "Bonne forme" / "Excellente forme"
        }
    }

    private static func genericMessage(for tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "Récupération conseillée aujourd'hui."
        case .prudence: return "Forme correcte — restez à l'écoute de vos sensations."
        case .opportunite: return "Vous êtes en forme — bon moment pour une séance clé."
        }
    }
}
```

Le `switch label` de `tier(for:)` dépend d'une chaîne produite par
`HealthScoreEngine.label(for:)` — un couplage textuel assumé plutôt qu'un
enum partagé, pour ne pas toucher `HealthScoreEngine` dans ce sous-projet.
Si `HealthScoreEngine.label(for:)` change un jour ses libellés, ce switch
doit changer avec — un commentaire dans le code source pointe vers
`HealthScoreEngine.label(for:)` pour ce couplage.

## 6. DashboardViewModel wiring

`DashboardViewModel.loadWellness()` (macOS) calcule déjà `readiness`. Ce
sous-projet y ajoute :

1. Le calcul de `LoadAssessment` via `TrainingLoadMonitor.assess(...)` —
   les mêmes entrées (`history`, `plan`, `readiness`, `today`, `calendar`)
   que celles déjà utilisées côté `TrainingViewModel`, mais lues depuis
   `DashboardViewModel` (qui a accès à `store`/`resolver`/`calendar`/`now`
   comme `TrainingViewModel`).
2. Le calcul de `VO2MaxStatus.alert` via `VO2MaxEngine.stagnationAlert(...)`
   — réutilise le `VO2MaxTrend` déjà calculé pour `InsightInputs.vo2Trend`
   (pas de second calcul de tendance), et `chronicWeeklyKm` déjà obtenu via
   `TrainingLoadMonitor` au point 1.
3. `dailyAdvice: DailyAdvice? = DailyAdviceEngine.advise(readiness:, loadAlerts:, vo2MaxAlert:)`,
   nouvelle propriété publiée sur `DashboardViewModel`.

`TrainingLoadMonitor.assess(...)` a besoin d'un historique de `Workout` —
que `DashboardViewModel` ne charge pas aujourd'hui. Ce sous-projet ajoute
ce chargement à `loadWellness()`.

**Décision prise avec Vincent (2026-08-30), à la lecture du code réel de
`TrainingViewModel.load()` :** l'appel passe `plan: nil`, jamais le
`TrainingPlan` complet. `ContentView.swift` appelle
`dashboardViewModel.load()` avant `trainingViewModel.load(readiness:)` —
le plan n'existe donc pas encore à ce stade, et le recalculer dans
`DashboardViewModel` demanderait de dupliquer le chargement des objectifs,
le calcul de `hrMax` sur 180 jours et l'appel à `TrainingPlanner.plan(...)`
de `TrainingViewModel.load()`. Avec `plan: nil`, `TrainingLoadMonitor.assess`
suit sa branche ACWR déjà prévue pour « sans objectif actif » (`highRatio`/
`lowRatio`) — les alertes spécifiques à un plan actif (dépassement, retard,
effondrement) restent invisibles pour ce conseil et continuent de
n'apparaître que sur Entraînement. Aucune duplication de code entre les
deux view models.

## 7. UI — écran Accueil

Nouvelle carte « Conseil du jour » dans `DashboardView.swift`, positionnée
**sous** la carte de score de forme (`readiness`) existante — jamais
au-dessus, pour que la lecture aille du score vers son implication. Rendue
seulement si `dailyAdvice != nil` (readiness disponible). Coexiste avec la
liste `insights` (`InsightsEngine`) déjà affichée ailleurs sur l'écran —
aucune des deux ne remplace l'autre.

Couleur/icône de la carte suit le `tier` (ex. teinte d'alerte pour
`.repos`, neutre pour `.prudence`, positive pour `.opportunite`) — détail
laissé à l'implémentation, cohérent avec le style déjà utilisé pour les
`LoadAlert.severity` sur Entraînement.

## 8. Error handling

- `readiness == nil` (données insuffisantes) → `dailyAdvice == nil` → carte
  non affichée. Pas de texte de repli inventé.
- Aucune alerte `.warning` disponible → texte générique du palier, jamais
  d'état d'erreur.
- Le chargement de l'historique de `Workout`/`TrainingPlan` dans
  `DashboardViewModel` suit la même gestion d'erreur que l'existant
  (`try` propagé, pas de `try?` silencieux) — cohérent avec la convention
  du dépôt de ne jamais avaler une erreur.

## 9. Code structure

- Create: `HealthCheckShared/Analysis/DailyAdviceEngine.swift`
- Modify: `HealthCheck/ViewModels/DashboardViewModel.swift` (chargement
  `LoadAssessment`/`VO2MaxStatus`, nouvelle propriété `dailyAdvice`)
- Modify: `HealthCheck/Views/DashboardView.swift` (nouvelle carte)
- Modify: `docs/METHODOLOGY.md` (nouvelle section `DailyAdviceEngine` —
  documente la composition et le couplage textuel de `tier(for:)`, ne
  redéfinit aucun seuil déjà documenté ailleurs)

Aucun fichier de `Companion/` ou `CompanionTests/` n'est touché.

## 10. Testing strategy

Convention du dépôt : toute garde de non-régression doit avoir été vue
échouer contre le bug qu'elle prétend attraper avant d'être acceptée.

Pour `DailyAdviceEngine` :
- Un test par palier (4 valeurs de `readiness.label` couvrant les 3 cas du
  `switch`, y compris que "Bonne forme" et "Excellente forme" retombent
  tous deux sur `.opportunite`) — falsifié en modifiant temporairement le
  `switch` pour renvoyer le mauvais palier et constater l'échec avant de
  restaurer.
- Un test « alerte `.warning` ignorée sous `.opportunite` » — falsifié en
  retirant temporairement la garde `tier != .opportunite` et en constatant
  que le test échoue (le texte de l'alerte remonte alors qu'il ne devrait
  pas).
- Un test de déterminisme : une alerte `.warning` dans `loadAlerts` ET une
  dans `vo2MaxAlert` simultanément → toujours celle de `loadAlerts` en
  premier (ordre de concaténation fixe) — falsifié en inversant l'ordre de
  concaténation dans le moteur et en constatant que le test échoue.
- Un test `readiness == nil` → `advise(...)` retourne `nil`.

Pour le câblage `DashboardViewModel` : couvert par extension de
`DashboardViewModelTests` existant (pas de nouvelle garde dédiée) — un cas
qui pose un historique de `Workout` + `TrainingPlan` connu et vérifie que
`dailyAdvice` reflète le palier attendu.

## 11. Known limitations (accepted)

- Le couplage textuel entre `DailyAdviceEngine.tier(for:)` et les libellés
  exacts de `HealthScoreEngine.label(for:)` est fragile aux renommages —
  accepté pour ce sous-projet plutôt que de faire dépendre
  `HealthScoreEngine` d'un enum partagé qui n'a d'utilité que pour ce
  conseil.
- Sous `.prudence` et `.opportunite`, seule la **première** alerte
  `.warning` trouvée est montrée — si plusieurs alertes `.warning`
  coexistent (ex. surcharge ET VO2max en baisse), les autres restent
  visibles uniquement sur Entraînement. Assumé : ce conseil est un résumé
  d'un message, pas une liste.
