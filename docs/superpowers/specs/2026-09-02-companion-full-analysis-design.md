# HealthCheck — Porter les écrans d'analyse du Mac sur le Companion

**Décisions prises avec Vincent (2026-09-02).** Demande initiale : « faire
évoluer l'application companion pour qu'elle intègre les indicateurs,
tableaux, analyse de l'application mac, en bref qu'elle ait les mêmes
éléments ». Brainstorming mené section par section ; les cinq questions
structurantes ont été tranchées explicitement avant la rédaction de ce
document :

1. **Périmètre** : les quatre blocs, sans exception — Activité + Sommeil +
   Séances, Entraînement, Tendances, Corrélations.
2. **Poids** : lu depuis HealthKit sur l'iPhone (voir §6, qui documente le
   renversement d'une règle antérieure et ses conséquences).
3. **Navigation** : `TabView` à 5 onglets, Synchro relégué dans Réglages.
4. **Partage** : les view models montent dans `HealthCheckShared/`, chaque
   plateforme garde ses vues.
5. **Ordre** : fondation d'abord, puis Activité + Sommeil.

## 1. Context and motivation

Le Companion est aujourd'hui une app à deux onglets : « Conseils »
(`CompanionAdvisorView` — forme, conseil du jour, tendance VO2max) et
« Synchro » (appairage, envoi au Mac, cache du plan d'entraînement). Le Mac,
lui, expose neuf sections : Accueil, Activité, Sommeil, Entraînement,
Séances, Corps, Tendances, Corrélations, Données.

Trois faits rendent le portage abordable, tous vérifiés dans le dépôt le
2026-09-02 :

- **Les 16 moteurs d'analyse sont déjà partagés** (`HealthCheckShared/Analysis/`)
  et compilent dans la cible iOS depuis le sous-projet 0 du 2026-08-28.
- **Les vues macOS n'utilisent pas AppKit**, à deux exceptions près
  (`ImportView`, `StoreErrorView`) qui ne sont pas dans le périmètre. Les
  écrans d'analyse sont du SwiftUI + Charts pur.
- **La base locale de l'iPhone contient enfin l'historique nécessaire** :
  depuis la séparation des ancres du 2026-09-02, elle couvre 180 jours
  (117 639 points de FC, 1 237 de HRV, 177 de FC repos, 119 de VO2max, 375
  nuits, 199 séances). Avant ce correctif, elle démarrait au 27 août et
  aucun de ces écrans n'aurait rien eu à afficher.

Ce qui manque n'est donc ni le calcul ni les données : c'est la couche
view model, restée côté Mac, et les vues.

## 2. Goals / Non-goals

**Goals.** Porter sur iPhone les sept écrans d'analyse du Mac, avec les
mêmes indicateurs et les mêmes règles de calcul, sans dupliquer une seule
règle métier. Garder l'autonomie acquise : aucun de ces écrans ne doit rien
attendre du Mac, ni de l'appairage.

**Non-goals.** L'import de l'export zip Apple Santé, l'OAuth et la synchro
Withings, la carte d'appairage côté Mac, Sparkle : ces écrans restent
exclusivement macOS. Le Sankey de répartition du poids (§6) n'est pas
portable faute de données. Aucune refonte visuelle du Mac n'est engagée
ici : le portage ne remonte pas dans l'autre sens.

## 3. Architecture: shared view models, platform-owned views

Les sept view models d'analyse remontent tels quels dans
`HealthCheckShared/ViewModels/`. Vérification faite avant d'écrire ce
document, ils ont tous la même forme et ne dépendent que de types déjà
partagés :

| View model | Init | Dépendances |
|---|---|---|
| `DashboardViewModel` | `(store:resolver:calendar:now:)` | `WellnessOrchestrator`, `InsightsEngine`, `DailyAggregator`, `DailyAdviceEngine`, `WeightEngine` |
| `ActivityViewModel` | `(store:resolver:calendar:now:)` | `StrainEngine`, `DailyAggregator` |
| `SleepViewModel` | `(store:resolver:calendar:now:)` | `SleepScoreEngine` |
| `TrendsViewModel` | `(store:resolver:calendar:now:)` | `SleepAggregator` |
| `CorrelationsViewModel` | `(store:resolver:calendar:now:)` | `CorrelationEngine`, `DailyAggregator`, `SleepAggregator` |
| `TrainingViewModel` | `(store:calendar:now:)` | `TrainingPlanner`, `TrainingLoadMonitor`, `VO2MaxEngine`, `SessionMatcher` |
| `WorkoutsViewModel` | `(store:routeStore:calendar:now:)` | `WorkoutStatsEngine`, `RouteStore` (déjà partagé) |

Un seul point d'attention dans ce tableau : `DashboardViewModel` appelle
`WeightEngine`, que `CompanionAdvisorViewModel` contournait jusqu'ici en
passant `weightAlert: nil`. Sur une base sans pesée, `WeightEngine` rend
`nil` et l'alerte n'apparaît pas — le view model partagé se comporte donc
correctement sur iPhone avant le SP5, et se met à produire l'alerte de
lui-même une fois le poids ingéré. Aucun traitement particulier n'est
nécessaire, mais c'est une garde à écrire au SP1 plutôt qu'une évidence à
supposer.

Aucun n'importe AppKit, ne lit l'environnement pour l'heure (`now` est
toujours injecté, conformément au CLAUDE.md du dépôt), ni ne touche à
Withings ou à l'import zip. La remontée est un déplacement de fichiers :
`project.yml` déclare les sources par chemin, les deux cibles reprennent le
nouveau répertoire sans autre modification.

Les vues restent propres à chaque plateforme. C'est le précédent établi par
l'onglet Conseils, dont l'en-tête documente déjà le choix : style visuel du
Companion, pas le gabarit du Mac. L'alternative — partager aussi les vues —
a été écartée : les fonds système, la densité et la navigation diffèrent,
les `#if os(iOS)` s'accumuleraient, et une retouche macOS pourrait casser
l'iPhone sans qu'aucun test ne le voie.

Ce qui reste côté Mac : `ImportViewModel`, `WithingsViewModel`,
`CompanionViewModel` (la carte d'appairage côté Mac), `BodyViewModel`
(construit sur l'API Withings, voir §6).

## 4. iOS navigation

`TabView` à cinq onglets, la limite au-delà de laquelle iOS empile le reste
derrière un menu « Plus » :

| Onglet | Écran | Sous-écrans (`NavigationStack`) |
|---|---|---|
| Accueil | `CompanionAdvisorView` enrichi des cartes du Dashboard | Tendances, Corrélations |
| Activité | pas, distance, énergie, minutes d'exercice | — |
| Sommeil | durées, scores, phases | — |
| Entraînement | charge, ACWR, VO2max, plan | Séances (avec traces GPS) |
| Corps | poids et masse grasse (§6) | — |

L'actuel `CompanionSyncView` devient accessible par un bouton Réglages dans
la barre de navigation d'Accueil : l'appairage est une configuration, pas
une destination quotidienne. Son contenu ne change pas.

## 5. Sub-projects

Chacun est livrable, testable et mergeable seul, et **chacun aura son
propre plan d'implémentation** : ce document est la spec du chantier
entier, pas d'une seule tranche.

**SP1 — Fondation.** Remontée des sept view models dans
`HealthCheckShared/ViewModels/`, `xcodegen generate`, vérification que les
deux cibles compilent et que les 279 tests macOS passent inchangés (aucun
changement de comportement attendu : c'est un déplacement). Nouvelle
navigation à cinq onglets avec des écrans encore vides, Synchro déplacé
dans Réglages. L'onglet Accueil garde à ce stade exactement les trois
cartes actuelles de « Conseils » : le remplacement de
`CompanionAdvisorViewModel` par le `DashboardViewModel` partagé arrive au
SP2, avec les données d'activité qui le nourrissent.

**SP2 — Activité + Sommeil, et enrichissement d'Accueil.** Les deux vues
iOS, câblées sur `ActivityViewModel` et `SleepViewModel`. Écrans les plus
simples (106 et 140 lignes côté Mac), données complètes en local : ils
valident la fondation sur un terrain sans surprise. Accueil bascule dans le
même mouvement sur `DashboardViewModel` et gagne ses résumés du jour et de
la semaine ainsi que les insights — ce sont les mêmes agrégats d'activité,
les porter séparément dupliquerait le travail de câblage.

**SP3 — Entraînement + Séances.** Le gros morceau : `TrainingView` fait 592
lignes, `WorkoutsView` 192, avec les cartes des traces GPS. Le plan
d'entraînement est déjà en cache localement (chantier du 2026-08-25) ; la
charge, l'ACWR et le VO2max se calculent localement.

**SP4 — Tendances + Corrélations.** Sélecteur de période à repenser pour
180 jours (§7).

**SP5 — Corps.** Isolé en dernier : c'est le seul sous-projet qui touche à
la synchro (§6).

## 6. Weight: read from HealthKit, never pushed

**Renversement d'une règle antérieure, tranché par Vincent le 2026-09-02.**
La spec du 2026-08-31 (§ correction post-approbation) actait l'inverse : le
poids restait « territoire Withings », jamais lu via HealthKit sur iPhone,
et `CompanionTests/HKMapperTests.swift` contient un test
(`test_unknownQuantityType_isDropped`) qui utilise précisément un
échantillon `bodyMass` comme exemple de type ignoré. Ce test devra être
réécrit sur un autre type inconnu, et la règle documentée à nouveau —
laisser deux documents affirmer le contraire l'un de l'autre serait pire
que le changement lui-même.

**Ce que ça implique techniquement.** `BodyMass`, `BodyFatPercentage` et
`LeanBodyMass` entrent dans `HKMapper.quantityUnits` avec leurs unités
épinglées (kg, %, kg), ce qui les fait entrer dans `readTypes` : iOS
redemandera l'autorisation au prochain lancement.

**Ils ne doivent jamais être poussés vers le Mac.** Celui-ci possède déjà
ces mesures via l'API Withings, avec d'autres identifiants ; les pesées ont
une durée nulle (`start == end`) et `SourcePriorityResolver` ne déduplique
pas ces échantillons-là — c'est le follow-up M2, toujours ouvert. Les
pousser créerait des doublons réels dans la base du Mac. La séparation des
ancres livrée le 2026-09-02 rend la solution directe : `SyncEngine` reçoit
**deux listes de types**, `typeIdentifiers` (les deux passes, comportement
actuel) et `localOnlyTypeIdentifiers` (la passe locale seulement). La passe
de push ignore la seconde liste.

**Fraîcheur des données, limite connue.** Dans la base du Mac,
`BodyMassIndex` — que seule Santé fournit — s'arrête au 18 juin 2026,
tandis que `BodyMass` continue jusqu'à aujourd'hui via l'API Withings.
L'inférence est que la synchro Withings → Santé est en panne depuis cette
date, donc que l'écran Corps de l'iPhone affichera des pesées figées à la
mi-juin. L'écran doit donc afficher la date de la dernière pesée de façon
visible plutôt que de laisser croire à une valeur du jour. Si la synchro
Withings → Santé est réparée (tâche ouverte dans TODOS.md), l'écran se
remplit tout seul, sans changement de code.

**Ce qui n'est pas portable.** Muscle, eau, os et graisse viscérale ne
transitent que par l'API Withings : le Sankey de répartition (`WeightSankeyView`)
et la partie composition corporelle de `BodyView` restent macOS. L'écran
Corps de l'iPhone se limite au poids et à la masse grasse.

## 7. Accepted limitations

**180 jours contre plusieurs années.** L'iPhone lit HealthKit sur une
fenêtre de 180 jours (`HealthKitReaderLive.initialWindowDays`) ; le Mac
possède l'historique complet depuis 2012 par l'import zip et l'API
Withings. Les périodes « 1 an » et au-delà du sélecteur de Tendances n'ont
donc pas de sens sur iPhone. Deux conséquences pour le design : le
sélecteur iOS s'arrête à 6 mois, et tout écran dont la fenêtre dépasse les
données disponibles affiche depuis quelle date il dispose de mesures — un
graphique qui commence brutalement en mars ne doit pas se lire comme un
trou dans les données.

**Corrélations moins solides.** `CorrelationEngine` gagne en fiabilité avec
le recul ; sur 180 jours, certaines cartes seront absentes faute
d'échantillons suffisants. Le comportement existant (une carte ne
s'affiche pas si l'échantillon est trop faible) suffit, aucun traitement
particulier n'est prévu.

**Pas de Sankey, pas de composition corporelle** (§6).

## 8. Testing

Règle du dépôt, non négociable : une garde de non-régression n'est acceptée
qu'après avoir été **vue échouer** contre le bug qu'elle prétend attraper.

- **SP1** : les tests existants des view models déplacés continuent de
  tourner dans la cible macOS, inchangés — c'est la garde du déplacement
  lui-même. S'y ajoute la vérification que la cible iOS compile ces mêmes
  fichiers.
- **SP2 à SP5** : chaque sous-projet teste son view model côté iOS sur des
  fixtures déterministes (`now` injecté, jamais `Date()`), et le câblage de
  sa vue. Les vues elles-mêmes ne sont pas testées — le dépôt n'a pas de
  harnais de vue, et en inventer un pour ce chantier serait hors sujet.
- **SP5** : garde spécifique et falsifiable — les types locaux seuls sont
  ingérés localement et n'apparaissent dans aucun batch poussé. Mutation de
  falsification : les réintégrer dans `typeIdentifiers`.

## 9. Risks

| Risque | Traitement |
|---|---|
| La remontée des view models casse le Mac | SP1 ne change aucun comportement ; les 279 tests macOS font foi avant/après |
| L'écran Corps affiche des données périmées sans le dire | Date de dernière pesée affichée en évidence (§6) |
| Tendances laisse croire à un trou de données avant mars | Mention explicite de la profondeur d'historique disponible (§7) |
| Le poids pousse des doublons vers le Mac | Liste de types locaux seuls, avec garde falsifiable (§8) |
| `TrainingView` (592 lignes) portée d'un bloc | SP3 la découpe en sous-vues au moment du portage, comme le Mac aurait dû le faire |
