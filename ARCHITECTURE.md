# Architecture — HealthCheck

Miroir français de `ARCHITECTURE_EN.md` (source de vérité) — éditer les
deux dans le même tour.

## Vue d'ensemble

App macOS native (SwiftUI, macOS 15+) d'analyse de santé personnelle.
Deux chemins de données alimentent un store SQLite local ; des moteurs
d'analyse purs calculent scores et statistiques ; les écrans SwiftUI
les affichent. Tout tourne en local — les seules requêtes réseau vont
vers l'API Withings quand l'utilisateur connecte son compte.

**Contrainte fondatrice :** macOS n'a aucun accès HealthKit. Le
framework se lie (le SDK le marque disponible depuis macOS 13) mais
`HKHealthStore.isHealthDataAvailable()` renvoie `false` — vérifié
empiriquement jusqu'à la beta macOS 27. Les données Apple Watch/iPhone
ne peuvent venir que de l'export zip manuel de l'app Santé.

## Flux de données

```
Zip Apple Santé ──► ZipExtractor ──► HealthExportParser (SAX) ─┐
                         │                                     │
                         └──► RouteStore (fichiers GPX)        ▼
                                                    ┌─────────────────┐
Cloud Withings ──► WithingsClient (OAuth2) ────────►│   HealthStore   │
                                                    │  (SQLite/GRDB)  │
                                                    └────────┬────────┘
                                                             │ lectures via
                                                             ▼ SourcePriorityResolver
                                            ┌────────────────────────────┐
                                            │  Moteurs d'analyse (purs)  │
                                            │  scores · zones · Pearson  │
                                            └────────────┬───────────────┘
                                                         ▼
                                            ViewModels (@MainActor)
                                                         ▼
                                            Vues SwiftUI (9 sections)
```

## Stockage

SQLite via GRDB, retenu contre SwiftData/Core Data après mesure de
l'export réel (844 Mo, 1,8 M de `<Record>`) : l'insertion bulk à cette
échelle est un risque sur un store managé. Transactions batchées
(5000 lignes/tx).

Trois tables, toutes avec une **clé primaire synthétique** = SHA256 de
(type, source, device, dates, valeur, unité) car Apple ne fournit
aucun ID stable. Combinée à `INSERT OR IGNORE`, chaque import et
chaque synchro Withings est idempotent — vérifié à l'échelle réelle
(réimport de 1,79 M d'enregistrements : 0 insertion).

| Table | Contenu | Notes |
|---|---|---|
| `health_record` | échantillons numériques (`type`, `value`, `unit`, dates, source) | index sur `(type, startDate)` — indispensable, les écrans interrogent par type+plage sur 2,2 M de lignes |
| `sleep_record` | segments de sommeil catégoriels (`value` = phase) | nuits regroupées par jour calendaire décalé de −12 h |
| `workout` | séances (type d'activité, durée+unité, distance, énergie, `routeFileName`) | fichiers GPX gérés à part par `RouteStore` |

Bornes de dates exclusives en haut (`startDate >= ? AND startDate < ?`) :
un échantillon de minuit ne compte jamais deux fois.

**Ouverture au lancement.** Une base illisible (corrompue, disque plein,
droits refusés) ne fait plus crasher l'app : `HealthCheckApp` capture
l'erreur, retient un `HealthStore(unavailable:)` sans base sous-jacente
— toutes ses méthodes lèvent `HealthStoreError.unavailable` — et
`body` affiche `StoreErrorView` **à la place de** `ContentView`. Le
remplacement est délibéré plutôt qu'une bannière superposée : l'import
doit rester inatteignable, un export de 844 Mo ne doit pas atterrir
dans un store jetable.

Les agrégats sur les séries à haute fréquence (FC continue : 388 k
lignes) se font en SQL (`maxValue`, `averageValue`) — ces séries ne
sont jamais chargées en mémoire.

## Pipeline d'import (Apple Santé)

1. `ZipExtractor` — `/usr/bin/unzip` via `Process` vers un dossier temp.
2. `RouteStore.importRoutes` — copie tous les `.gpx` vers
   `Application Support/HealthCheck/routes/` avant le nettoyage du
   temp. Accès aux fichiers par dernier composant de chemin uniquement
   (pas de traversée).
3. `HealthExportParser` — SAX streaming (`XMLParser` sur
   `InputStream`), jamais de DOM. Types/attributs inconnus ignorés,
   jamais fatals : Apple change ce schéma entre versions d'iOS sans
   préavis.
4. `HealthExportImporter` — buffers de 5000, flush par lot. Les
   erreurs de flush en cours de stream sont capturées et relancées
   après le parsing (un `try?` les avalait silencieusement — testé en
   régression depuis).

## Résolution de priorité de source

**La correspondance des noms se fait par sous-chaîne, insensible à la
casse** (2026-09-03). Le `sourceName` d'un échantillon est le nom que
l'utilisateur a donné à son appareil — « Apple Watch de Vincent », « iPhone
☠️ » — jamais le mot nu « Watch ». L'égalité stricte d'origine ne
reconnaissait donc aucune source réelle : la priorité n'était jamais
appliquée et, sur un chevauchement, le premier échantillon rencontré
l'emportait. Les quatre tests du résolveur passaient parce qu'ils
construisaient leurs fixtures avec « Watch » et « iPhone » nus.

`SourcePriorityResolver` dédoublonne les échantillons chevauchants de
plusieurs sources (Watch > iPhone) **à la lecture** — la donnée brute
reste intacte en base. Implémentation : balayage sur les
enregistrements triés par début avec fenêtre d'intervalles encore
ouverts. Ne jamais revenir à un scan linéaire de tout `kept` : c'est
O(n²) et ça gelait le MainActor plusieurs secondes sur 28 k
échantillons d'énergie.

Les mesures ponctuelles (FC continue) sautent la résolution : des
intervalles de durée nulle ne se chevauchent jamais, les doublons
pèsent 0 minute par construction.

## Moteurs d'analyse (purs, tous testés)

Tous les moteurs sont des fonctions pures `nonisolated` sur des types
valeur — pas de SwiftUI, pas de store, testables au centième.

| Moteur | Sortie | Formules clés |
|---|---|---|
| `HealthScoreEngine` | forme 0-100 | poids sommeil 0,35 / FC repos 0,30 / HRV 0,25 / activité 0,10, renormalisés sur les composantes disponibles ; baselines = moyennes 30 j, min 5 échantillons |
| `SleepScoreEngine` | score de nuit 0-100 + `NightSummary` | durée 50 pts (cible 8 h), profond 20 (≥15 %), REM 20 (≥20 %), continuité 10 ; repli durée seule sans phases |
| `StrainEngine` | `DayStrain` (minutes Z1-Z5 + score) | zones à 50-90 % de la FC max observée sur 2 ans (bornée 140-210) ; poids 1/2/4/7/10 ; trous entre échantillons plafonnés à 5 min ; 600 pts de charge = 100 |
| `InsightsEngine` | phrases en français | règles : FC repos ±3 %, sommeil <7 h (garde-fou ≥3 nuits), pas ±20 % à période écoulée égale, VO₂ +1, poids ±1 kg/30 j |
| `BodyCompositionEngine` | séries `BodySnapshot` + `WeightSankey` | masse grasse = poids × part ; snapshots joints sur les jours de pesée ; le niveau 2 du Sankey omet un reste incohérent (mesures de jours différents) |
| `WorkoutStatsEngine` | volumes hebdo + libellés | durée normalisée par unité (min/s/h) ; 20 types traduits en français, repli sans préfixe |
| `CorrelationEngine` | r de Pearson + paires | refuse <10 paires et variance nulle ; x du jour D apparié au y du jour D+décalage (la nuit étiquetée D influence le matin D+1) |
| `GPXParser` | `[RoutePoint]` | SAX, seulement les `trkpt` lat/lon, sans MapKit |

## Plan d'entraînement

Trois moteurs purs sous `HealthCheck/Analysis/` transforment un
objectif de course en plan semaine par semaine, rapprochent le réalisé
du plan, et surveillent la charge d'entraînement. `TrainingViewModel`
(`HealthCheck/ViewModels/TrainingViewModel.swift`) est le seul à les
composer — il recalcule `goal`/`plan`/`progress`/`assessment` depuis
zéro à chaque `load()`, rien n'est persisté, donc l'écran ne peut
jamais diverger de ce que produirait un appel direct aux trois moteurs
pour les mêmes entrées.

- **`TrainingPlanner`** construit un `TrainingPlan` déterministe à
  partir d'un `RaceGoal`, de l'historique de course et de `hrMax`. Le
  volume hebdomadaire de départ est le plus grand de la charge
  chronique, de la charge aiguë et d'un plancher à 10 km ; il monte
  géométriquement — ×1,15/semaine tant que ce volume hebdomadaire de
  départ est sous la distance de l'objectif, ×1,10/semaine une fois à
  son niveau ou au-delà —
  plafonné à 1,5× la distance de l'objectif, culmine deux semaines
  avant la course, puis redescend par ×0,75 puis ×0,5 jusqu'à la
  semaine de course. La cible de chaque semaine se répartit en sortie
  longue (part de 60 %, croissance plafonnée à 2,5 km/semaine par
  rapport à la plus longue sortie des 14 derniers jours), séance de
  côtes (part de 25 %, dénivelé monté de 100 m vers
  `min(300, goal.elevationGainM × 0,75)`), endurance fondamentale pour
  le reste, et une séance optionnelle facile.
- **`SessionMatcher`** rapproche les sorties réellement courues d'une
  `PlannedWeek` : les séances définies en distance sont appariées par
  taille (la plus grosse sortie sur la plus grosse cible d'abord), les
  séances définies en durée (déverrouillage, optionnelle) récupèrent
  ce qui reste, une séance est comptée faite à 70 % de sa distance
  cible, et les sorties non appariées ressortent séparément comme
  `offPlan`. Recalculer ce rapprochement à chaque chargement est ce qui
  permet à une séance fraîchement synchronisée de basculer sur « fait »
  sans aucune action manuelle.
- **`TrainingLoadMonitor`** surveille le volume aigu (7 jours) contre
  le volume chronique (28 jours, moyenne sur 4 semaines) et en tire des
  `LoadAlert`, selon l'un de deux régimes (ci-dessous).

**Le motif de la séance vit dans le moteur, pas dans la vue.** Chaque
`PlannedSession` porte un `rationale` distinct de `note` : `note` est
l'instruction (comment la faire), `rationale` est le pourquoi — et il
dépend à la fois du genre de séance *et* du rôle de la semaine, car une
sortie longue en semaine de pic et une en affûtage ne se justifient pas
de la même façon. Seul `TrainingPlanner` connaît les deux, donc seul
lui peut produire ce texte. Pour la même raison, `TrainingPlan` expose
`anchorBaseKm` et `rampFactor`, déjà calculés à l'ancrage, ainsi qu'un
`longestPlannedRunKm` calculé, pour que l'écran d'entraînement puisse
s'expliquer lui-même — d'où part le plan, de combien il monte, et à
quel point sa plus longue sortie reste en-deçà de la distance de
course — sans rien recalculer que le moteur sait déjà.

**Une seule définition de la charge chronique, partagée.**
`TrainingPlanner.chronicWeeklyKm` et `TrainingPlanner.acuteKm` sont les
seules définitions de charge « chronique » et « aiguë » de tout le
code — `TrainingLoadMonitor` les appelle directement plutôt que de
garder sa propre lecture. Si les deux divergeaient, le moniteur
pourrait alerter sur un ratio que le planificateur vient lui-même de
construire pour la cible de la semaine ; partager la définition est ce
qui rend les alertes relatives au plan (ci-dessous) réellement
cohérentes avec le plan affiché à l'écran.

**Alertes relatives au plan, et pourquoi l'ACWR brut doit rester
silencieux face à une montée en charge.** Sans objectif actif,
`TrainingLoadMonitor` retombe sur le ratio classique aigu/chronique
(ACWR) — au-dessus de 1,3 il alerte « vous progressez trop vite », en
dessous de 0,8 il suggère d'en faire un peu plus. Mais la montée en
charge de `TrainingPlanner` est plafonnée par construction
(×1,10-1,15/semaine) ; une semaine qui suit exactement la progression
prescrite par le plan peut quand même afficher un ACWR brut supérieur
à 1,3, en particulier en début de reprise où la montée géométrique est
la plus raide par rapport à une base basse. Déclencher « vous
progressez trop vite » à côté d'une carte de plan qui vient elle-même
de prescrire cette hausse serait contradictoire. Donc dès que la
semaine en cours est présente dans `plan.weeks` et porte des cibles
(`role != .currentWeekClosing`), `assess` compare le réalisé à *la
cible de cette semaine* plutôt qu'au ratio brut — dépasser la cible de
25 % alerte, être en retard de 50 % avec ≤2 jours restants dans la
semaine signale qu'elle ne sera pas rattrapée, et une forme du jour
basse suggère d'intervertir une sortie longue ou de côtes encore en
attente avec une séance facile. Le repli sur le ratio brut est
conditionné à l'**absence de plan** (`plan == nil`), et non au résultat
de la recherche de semaine. La distinction est tout sauf théorique :
`TrainingPlanner` marque la semaine en cours `currentWeekClosing` dès
qu'il y reste moins de trois jours, donc une garde portant sur la
semaine aurait fait réapparaître « vous progressez trop vite » chaque
samedi et dimanche, à côté d'un plan respecté — exactement la
contradiction que cette conception élimine. Quand un plan existe mais
que la semaine en cours ne porte pas de cibles, `assess` publie
toujours charge aiguë, chronique et ratio pour l'affichage, mais
n'émet aucune alerte : il n'y a pas de cible à laquelle comparer, et le
ratio brut est précisément le nombre qui ne doit pas piloter d'alerte
tant qu'un plan est actif.

**Ancré à la création, jamais recalculé depuis aujourd'hui.** La
séquence des semaines se déduit de `goal.createdAt` — la règle de
semaine de départ du §5.2 s'applique une seule fois, à la création — et
la cible d'une semaine se reporte de proche en proche au lieu d'être
redérivée. Une semaine passée ou en cours monte depuis la charge
mesurée **strictement avant son propre lundi**, plafonnée par la cible
de la semaine précédente ; une semaine **future** est une pure
projection depuis la cible précédente et ne lit aucune charge. Recalculer
l'une ou l'autre depuis `today` semblait anodin et cassait trois choses
à la fois : la cible de la semaine en cours courait après le volume
déjà réalisé (le plan bougeait donc tout seul chaque jour), l'horizon
se réduisait jusqu'à faire basculer tout plan dans la branche de
maintien `<= 2` à deux semaines de l'échéance (détruisant le relâchement),
et — le pire — l'alerte de surdosage devenait arithmétiquement
inatteignable, puisqu'une cible qui grandit pour rejoindre le réalisé ne
peut jamais être dépassée de 25 %. Un coureur faisant le double du
volume prescrit ne recevait aucun avertissement. Le plafond
`min(mesuré, ciblePrécédente)` est la règle de non-rattrapage : une
semaine courue en deçà rebase les suivantes vers le bas, une semaine
dépassée ne les relève jamais. Il n'a pas de plancher, donc une semaine
sautée peut faire tomber tout l'arc restant — 78 % de chute mesurée sur
le cas d'or. Le choix retenu est de garder ce rebasage et de le **dire**
plutôt que d'ajouter un plancher qui décrocherait le plan de la réalité :
`TrainingLoadMonitor` lève un avertissement dès que la cible de la
semaine en cours passe sous `collapseFactor` (0,6) de celle de la semaine
de plan précédente, les deux étant des semaines de rampe (un relâchement
baisse par construction). Le message nomme les deux cibles et la sortie
de secours — recréer l'objectif réancre la semaine 0 sur
`max(charge mesurée, 10 km)` (spec §5.2bis).

**Le dénivelé est prescrit, jamais vérifié.** Chaque `PlannedSession`
porte un `targetClimbM`, monté vers `goal.elevationGainM` de la même
façon que la distance — mais aucune partie de l'import, de la synchro
compagnon ou du modèle `Workout` ne capture de dénivelé nulle part
dans le pipeline (spec de conception §6.1). `SessionMatcher` apparie et
marque les séances « faites » sur la seule distance ; vérifier une
cible de dénivelé demanderait des données d'altitude tirées du GPX que
rien dans ce code n'extrait — le chiffre de dénivelé sur une séance de
côtes est une indication à lire par le coureur, pas quelque chose que
l'app peut contrôler.

## Intégration Withings

Comble ce que HealthKit ne peut pas : muscle, eau, os et graisse
viscérale n'ont **aucun type HealthKit** — Withings les garde dans son
cloud et ne synchronise vers Apple Santé que poids/% graisse/maigre/IMC.

- **OAuth2** : autorisation navigateur sur `account.withings.com`,
  callback capté par un `NWListener` éphémère sur `localhost:8723`
  (l'URI enregistrée), code échangé sur `wbsapi.withings.net/v2/oauth2`.
  Paramètre `state` vérifié.
- **Jetons** : dans `Application Support/HealthCheck/` (`withings.json`
  identifiants, `withings-tokens.json`, chmod 600, hors dépôt et hors
  bundle). Le refresh token est à usage unique : réécrit après chaque
  rafraîchissement.
- **Synchro** : `getmeas` paginé (meastypes 1, 5, 6, 76, 77, 88, 170).
  Valeur réelle = `value × 10^unit` ; le taux de graisse est divisé
  par 100 pour suivre la convention en fraction de l'export. Les types
  ayant un équivalent HealthKit reprennent les mêmes identifiants pour
  que les écrans existants les voient ; les quatre autres utilisent
  des types custom `Withings*`.
- **Auto-synchro** : au lancement si connecté et dernière synchro
  >12 h (`shouldAutoSync`, pur et testé).
- Entitlements sandbox : `network.client` + `network.server`
  (listener loopback).

## Synchro compagnon (récepteur Mac)

Chemin pair-à-pair pour une future app compagnon iOS (suivie
séparément) qui pousserait les données HealthKit directement vers le
Mac, sans passer par l'export zip manuel. Ce chantier livre uniquement
le récepteur côté Mac — pas encore de client iOS.

- **Listener** : `SyncServer` encapsule un `NWListener` éphémère
  (`.tcp`, port attribué par le système) annoncé en Bonjour sous
  `_healthcheck._tcp`. Démarré hors du main actor (`Task.detached`)
  depuis le `.task` de `ContentView` — le tout premier bind peut
  déclencher l'invite système d'accès au réseau local, et `start()`
  bloque jusqu'à 2 s en attendant l'état `.ready` ; le main actor ne
  doit jamais attendre là-dessus. `stop()` existe mais n'est appelé
  nulle part dans l'app — une course à l'arrêt du listener rend les
  chemins d'arrêt non sûrs tant qu'ils ne sont pas synchronisés (suivi
  séparément).
- **Endpoints** : parsing HTTP/1.1 minimal fait maison
  (`SyncHTTPRequest`/`SyncHTTPResponse`, `Connection: close`), routé
  par la fonction pure `CompanionRouter.handle` :
  - `POST /pair` — échange un code d'appairage, retourne
    `{"token": …}`.
  - `POST /batch` — authentifié par Bearer, ingère un `ExchangeBatch`
    (records/sommeil/séances), retourne `{"inserted": N}`.
  - `GET /status` — authentifié par Bearer, vérification de santé (nom
    de l'app + version).
- **Appairage** : `PairingManager` ouvre une fenêtre à code 6 chiffres
  (120 s, 5 tentatives). À l'échange, un jeton hexadécimal de 32
  octets est émis et persisté par `CompanionTokenStore`
  (`companion-token.json` dans Application Support, chmod 600) — même
  posture que les jetons Withings.
- **Ingestion idempotente** : `CompanionImporter.ingest` réutilise les
  chemins d'insertion existants du store (`insertRecords`/
  `insertSleepRecords`/`insertWorkouts`) — idempotente via les mêmes
  clés synthétiques + `INSERT OR IGNORE` que le pipeline zip. Les
  traces GPX des séances sont écrites avant la ligne de séance, nommées
  de façon déterministe (`companion_<ISO8601>_<activityType>.gpx`) ;
  `routeFileName` est stocké de façon auto-cicatrisante dès que les
  points de trace ne sont pas vides, même si l'écriture GPX échoue —
  une relivraison du même batch répare le fichier manquant sous le
  même nom.
- **Protocole partagé** : `HealthCheckShared/ExchangeModels.swift` est
  compilé dans les deux apps via un groupe source partagé (pas de
  framework) — une seule définition des DTO, des endpoints et du type
  de service Bonjour, aucune dérive possible entre les deux côtés.
- **Rafraîchissement** : `CompanionViewModel.syncGeneration` s'incrémente
  à chaque insertion réussie ; le `onChange(of: … syncGeneration)` de
  `ContentView` recharge les sections alimentées par le compagnon
  (effort, sommeil, bien-être, séances, corrélations, tendances) — pas
  le corps, qui reste le territoire de Withings. Reproduit exactement
  le handler Withings existant, y compris sa période `.sixMonths`
  figée en dur pour les tendances (défaut connu et accepté, suivi dans
  `TODOS.md` pour être corrigé sur les deux en même temps).
- Sandbox de l'app : déjà couvert par l'entitlement `network.server`
  ajouté pour le listener loopback OAuth Withings — aucun changement
  requis.

## App compagnon (iOS)

La cible `HealthCheckCompanion` (iOS 17+) est le client qui parle au
récepteur Mac ci-dessus — HealthKit sur le téléphone, sans export
manuel.

- **Mapper** : `HKMapper` convertit `HKQuantitySample`/
  `HKCategorySample`/`HKWorkout` vers les DTO d'échange partagés, avec
  les unités épinglées relevées sur la base Mac réelle (spec §4, ex.
  km pour la distance, mL/min·kg pour le VO₂ max) — le Mac les ingère
  sans aucune conversion.
- **Ancres à avancement conditionné à l'ack** : `SyncEngine` lit un
  `TypeDelta` par type via `DeltaReading` (`HealthKitReaderLive`,
  adossé à `HKAnchoredObjectQuery`), le pousse en batchs
  ≤ `batchLimit`, et n'appelle `AnchorStore.save` qu'une fois TOUS les
  batchs de ce delta ackés — livraison at-least-once ; l'ingestion
  idempotente du Mac absorbe toute relivraison après un échec en cours
  de delta. Un 401 positionne `needsPairing` et arrête la boucle :
  inutile d'insister sans jeton valide.
- **Accueil partagé jusqu'aux agrégats** (2026-09-02) : `PeriodSummaryEngine`
  (totaux d'une fenêtre, journée, semaine à portion écoulée égale) et
  `InsightInputsBuilder` (entrées d'`InsightsEngine`, avec son plancher de
  trois nuits) sont extraits de `DashboardViewModel` dans
  `HealthCheckShared/Analysis/`. Le Mac les appelle depuis
  `loadToday`/`loadThisWeek`/`loadWellness`, l'iPhone depuis la passe
  détachée de `CompanionAdvisorViewModel` — qui garde donc son calcul hors
  `MainActor`, son compteur de génération et son état `storeUnavailable` tout
  en affichant les mêmes chiffres.
- **View models d'analyse partagés** (2026-09-02) : les sept view models
  d'analyse (`Dashboard`, `Activity`, `Sleep`, `Trends`, `Correlations`,
  `Training`, `Workouts`) vivent dans `HealthCheckShared/ViewModels/` et sont
  compilés par les deux cibles. Ils ne dépendent que de `HealthStore`,
  `SourcePriorityResolver` et `RouteStore`, tous déjà partagés. Restent
  propres au Mac ceux qui ne le peuvent pas : `BodyViewModel` (API Withings),
  `ImportViewModel` (export zip), `WithingsViewModel`, `CompanionViewModel`
  (serveur d'appairage).
- **Deux jeux d'ancres, un par consommateur** (2026-09-01) :
  `anchors` (répertoire `anchors`) gouverne le push vers le Mac et
  n'avance qu'à l'ack ; `anchors-local` gouverne l'ingestion dans la
  base de l'iPhone et avance dès l'insertion réussie, sans rien
  attendre du Mac. Chaque passe lit donc le type deux fois. Les
  partager avait deux effets : l'autonomie de l'iPhone dépendait de
  l'appairage, et surtout la base locale — introduite le 2026-08-28,
  bien après les premières synchros — ne pouvait plus jamais recevoir
  l'historique que ces synchros avaient déjà consommé. Une ancre locale
  vierge repart de la fenêtre initiale de 180 jours
  (`HealthKitReaderLive.initialWindowDays`), ce qui rattrape cet
  historique une fois pour toutes.
- **Découverte Bonjour** : `BonjourEndpointProvider` parcourt
  `_healthcheck._tcp`, puis résout l'endpoint en ouvrant une connexion
  TCP éphémère et en lisant `host`/`port` sur son chemin « prêt » —
  formaté immédiatement en hôte compatible URL (`BonjourEndpointProvider
  .urlHost(for:)` met les adresses IPv6 entre crochets et
  percent-encode le scope `%iface` d'un lien local). Le port du
  listener Mac est lui-même éphémère et change à chaque lancement de
  l'app Mac, donc `MacClient` mémorise l'endpoint résolu pour toute sa
  durée de vie (une seule instance persiste tant que l'app tourne) au
  lieu de le redécouvrir à chaque requête HTTP. Si une requête échoue
  sur une adresse SERVIE PAR LE CACHE (port périmé après un
  redémarrage du Mac entre deux synchros), `MacClient` invalide le
  cache et retente une fois avec une adresse fraîche avant de faire
  remonter `.unreachable` ; un échec sur une résolution déjà fraîche
  (Mac réellement injoignable) ne déclenche pas de second essai. La
  découverte n'a donc lieu qu'une fois par tentative de synchro dans le
  cas nominal, deux si le port a changé depuis la dernière synchro.
- **Jeton Keychain** : `KeychainTokenStore` détient le jeton Bearer
  (compte `mac-token`) dans le trousseau iOS. Une réponse `401`/
  `needsPairing` l'efface et fait basculer le view model en
  « non appairé » — seul un nouvel appairage permet de récupérer.
- **Livraison en arrière-plan** : `BackgroundSync` enregistre une
  `HKObserverQuery` par type plus `enableBackgroundDelivery` —
  `.immediate` pour les métriques quotidiennes (sommeil, FC repos,
  HRV, VO₂ max), `.hourly` pour les flux denses (pas, distance,
  énergie active, minutes d'exercice, FC). La livraison est
  opportuniste — iOS ne garantit aucun horaire — donc le bouton manuel
  « Synchroniser » de `CompanionRootView` reste le recours fiable.
- **Clé de dédoublonnage normalisée** : les deux chemins d'ingestion
  décrivent la même mesure autrement — l'export zip n'horodate qu'à la
  seconde, arrondit la valeur et porte le `device` réel, là où
  `HKMapper` émet `device: nil` avec la pleine précision de
  `HKQuantity`. `DedupKey`
  (`HealthCheckShared/Models/DedupKey.swift`) neutralise ces trois
  écarts pour les trois modèles stockés : dates tronquées à la
  seconde, valeurs à quatre décimales (la précision de l'export),
  `device` exclu de la clé — c'est une métadonnée sur l'appareil, pas
  l'identité de la mesure. `creationDate` n'y entre pas non plus.
  Auparavant la clé divergeait sur ces trois champs et `INSERT OR
  IGNORE` ne fusionnait jamais les deux lignes. Cette architecture
  affirmait que `SourcePriorityResolver` absorbait le chevauchement à
  la LECTURE : ce n'est vrai que des échantillons à intervalle qui se
  chevauchent (pas, énergie, temps d'exercice), tous lus via
  `resolver.resolve`. Les échantillons ponctuels — FC, FC de repos,
  HRV, VO2max — ont `startDate == endDate`, ne se chevauchent donc
  jamais, et rien ne les fusionnait : 31 409 lignes en double relevées
  sur la base réelle, qui biaisaient toutes les moyennes de ces types
  et faisaient diverger le Mac de l'iPhone sur Accueil et
  Entraînement. `HealthStore.migrateDedupKeys` porte la migration
  unique (`PRAGMA user_version = 1`) qui recalcule les `id` et fusionne
  l'existant, en gardant la ligne la plus informative (trace GPX
  d'abord pour une séance, puis horodatage à la milliseconde). Elle
  n'est pas un nettoyage optionnel : sans elle, le premier import
  d'export zip après le changement de clé ne reconnaîtrait plus aucune
  ligne existante et redoublerait la base entière.
- **Répartition simulateur/appareil des tests** : les 64 cas XCTest du
  compagnon (mapper, persistance, moteur de synchro, stub client Mac,
  formatage d'endpoint Bonjour, fusion des réveils concurrents,
  protocole partagé, view model, view model de conseils/forme) tournent entièrement sur le
  simulateur iPhone 17. La vraie découverte Bonjour sur le réseau
  local et le timing de réveil en arrière-plan ne peuvent pas s'y
  exercer (pas de pairs sur le réseau local, pas de vrai réveil
  arrière-plan) et sont validés manuellement sur un iPhone physique —
  voir [docs/companion-setup.md](docs/companion-setup.md) et la liste
  de validation sur appareil qu'il documente.
- **Interface** : `CompanionRootView` est un `TabView` à cinq onglets
  (2026-09-02, SP1 du portage des écrans d'analyse) — Accueil, Activité,
  Sommeil, Entraînement, Corps. Activité et Sommeil affichent les mêmes
  indicateurs que le Mac (effort du jour par zone de FC et histogramme 14
  jours ; dernière nuit par phases, 14 nuits et moyennes), calculés par
  `ActivityViewModel` et `SleepViewModel` partagés. Entraînement
  (2026-09-02, SP3) montre la charge, le rapport aigu/chronique et le
  VO2max calculés localement par le `TrainingViewModel` partagé, puis le
  plan d'entraînement issu du cache alimenté par le Mac. Deux sources dans
  un même écran, chacune à sa place : la table `race_goal` est vide sur
  l'iPhone — les objectifs de course se créent sur le Mac — et
  `TrainingViewModel` traite ce cas explicitement, en produisant quand même
  l'évaluation de charge ; c'est le mode « entre deux courses », et une
  garde iOS le vérifie (`TrainingViewModelIOSTests`). Le plan en cache
  vivait dans l'écran de synchro jusqu'au SP3 : il a déménagé ici, parce
  que l'appairage est une configuration et le plan un contenu quotidien. De
  cet onglet part le sous-écran Séances (`CompanionWorkoutsView`) : volume
  hebdomadaire empilé par activité sur douze semaines, puis les sorties
  récentes avec leurs chiffres — chacun affiché seulement s'il existe, jamais
  de zéro fabriqué — et, quand la séance en porte une, sa trace GPS
  (`CompanionRouteMapView`, équivalent iOS de `RouteMapView`, même
  `GPXParser` partagé). Les GPX viennent du `RouteStore` de `LocalStore`,
  celui que `CompanionImporter` remplit en lisant HealthKit — jamais le
  `RouteStore()` par défaut, qui pointe ailleurs et ne trouverait aucun
  fichier.
  De l'Accueil partent deux autres sous-écrans (2026-09-03, SP4) :
  Tendances (`CompanionTrendsView`) — quatre courbes, FC de repos, poids,
  VO2max et sommeil, chacune doublée de sa moyenne mobile 7 jours — et
  Corrélations (`CompanionCorrelationsView`), les cinq mêmes questions que
  sur le Mac avec leur r, leur lecture en français et leur nuage de points.
  Des sous-écrans, pas des onglets : cinq est la limite au-delà de laquelle
  iOS empile le reste derrière un menu « Plus ». Deux mesures rendent
  Tendances honnête sur ce que l'iPhone possède, et l'une sans l'autre
  serait insuffisante : le sélecteur s'arrête à 6 mois
  (`TrendPeriod.companionCases`), parce que HealthKit n'est lu que sur
  `HealthKitReaderLive.initialWindowDays` (180 jours) et qu'une courbe
  « 1 an » commencerait à mi-axe, indiscernable d'un trou ; **et** l'écran
  annonce la date de la plus ancienne mesure
  (`TrendsViewModel.earliestMeasurement`) quand l'historique est plus court
  que la période demandée — un compte HealthKit récent n'a que quelques
  semaines de recul même sur 6 mois. « 6 mois » est le cas limite assumé :
  en mois calendaires il remonte jusqu'à 184 jours, quatre au-delà de la
  fenêtre, une amorce manquante de l'ordre du jour et non du mois.
  Corrélations n'a rien à borner : `CorrelationsViewModel.windowDays` vaut
  déjà 180, exactement la fenêtre HealthKit. `MetricStyle` est remonté dans
  `HealthCheckShared/Views/` pour que chaque métrique garde la même couleur
  sur les deux cibles.
  Corps (`CompanionBodyView`, 2026-09-03, SP5) affiche la dernière pesée avec
  **sa date en clair**, le taux et la masse grasse, les masses maigres, les
  écarts à 30 jours et 1 an, et une courbe de poids sur la période choisie.
  La date n'est pas un ornement : la synchro Withings → Santé est en panne
  depuis le 18 juin 2026, donc l'écran montre couramment une pesée de
  plusieurs semaines, et la donner pour la valeur du jour serait le vrai
  défaut. Ni Sankey ni composition corporelle — muscle, eau, os et graisse
  viscérale ne transitent que par l'API Withings, que l'iPhone n'appelle pas ;
  sur cette cible les quatre séries de `WithingsMeasureType` sont donc
  toujours vides, `weightSankey` est `nil`, et une garde iOS le vérifie plutôt
  que de le laisser découvrir.

  **Le poids est lu, jamais poussé.** `HKMapper` connaît désormais `BodyMass`,
  `BodyFatPercentage` et `LeanBodyMass` — ils entrent donc dans `readTypes` et
  iOS en redemande l'autorisation. Mais `SyncEngine` porte **deux** listes :
  `typeIdentifiers`, que les deux passes consomment, et `localOnlyTypes`, que
  seule l'ingestion locale consomme. Le Mac possède déjà ces mesures via
  l'API Withings sous d'autres identifiants de source, et une pesée ayant une
  durée nulle, `SourcePriorityResolver` ne la dédoublonne pas (suivi M2) : les
  pousser créerait de vrais doublons. `syncAll()` ingère donc ces types
  localement **avant** sa boucle de push — sans quoi « Envoyer au Mac »
  sauterait silencieusement le poids — et la garde
  (`SyncEngineTests.test_syncAll_ingestsLocalOnlyTypesLocallyAndPushesNoneOfThem`)
  observe ce qui atteint le pousseur, jamais la composition des listes, qui
  serait vraie par construction. Deux détails valent d'être écrits : le taux
  de graisse est stocké en **fraction** (0,25 et non 25), comme l'export Apple
  Santé et l'API Withings, et le libellé d'unité (`kg`, `%`) entre dans
  `DedupKey` — s'en écarter recréerait les doublons supprimés le 2026-09-03.

  **La profondeur de mesure remonte jusqu'à l'écran.** La valeur « du jour »
  d'une composante de forme est la moyenne des échantillons connus à cet
  instant : le 2026-09-02, la même journée valait 57,0 vue à une mesure de VFC
  et 95,4 vue à neuf. `TrendPoint.sampleCount`, rempli par `DailyAggregator`,
  traverse `WellnessOrchestrator.split` — qui rend désormais le `TrendPoint` et
  non sa seule valeur — jusqu'à `ScoreComponent.sampleCount`, affiché par les
  deux applications. Le calcul est inchangé : c'est un défaut d'information,
  pas de formule, et un seuil de refus serait arbitraire là où un compte
  affiché ne l'est pas.

  **Le score de forme dit maintenant ce qu'il n'a pas mesuré.** Une composante
  absente ne pénalise pas le score : `HealthScoreEngine.readiness` retire son
  poids du panier et renormalise. Sans rien afficher, un score amputé du
  sommeil (0,35, le poids le plus lourd) montrait « Excellente forme » à 97/100
  — constaté sur les données réelles le 2026-09-03. `ReadinessScore` porte donc
  `missing` (composante, poids nominal, raison en clair) et `ScoreComponent`
  porte `share`, la part réelle après redistribution ; les deux applications
  les affichent, et `HealthScoreEngine.formulaExplanation` — écrite contre la
  table des poids qu'elle cite, pour ne pas en dériver — donne la formule dans
  les deux. Le Companion affichait jusqu'ici le seul nombre, là où le Mac
  détaillait déjà les composantes : c'est ce qui rendait un écart entre les
  deux applications impossible à expliquer depuis l'iPhone.

  Conséquence immédiate, et corrigée dans la foulée : l'Accueil du Companion
  lit désormais le poids lui aussi. `CompanionAdvisorViewModel.defaultCompute`
  reprend les 30 jours, l'agrégation quotidienne et les appels à `WeightEngine`
  de `DashboardViewModel.load()`, et transmet l'alerte de rythme à
  `DailyAdviceEngine`. Sans cela les deux Accueils auraient donné des conseils
  différents sur les mêmes données — la divergence même que ce sous-projet
  devait supprimer, mais réintroduite par construction. L'appairage et l'envoi au Mac, qui formaient un
  onglet, sont passés derrière un bouton Réglages présenté en feuille :
  c'est une configuration, pas une destination quotidienne. Accueil
  (`CompanionAdvisorView`) affiche forme, conseil du jour
  et tendance VO2max calculés localement par
  `CompanionAdvisorViewModel`, indépendamment de l'appairage avec le
  Mac ; il se rafraîchit sur la première apparition, sur toute synchro
  manuelle, au retour au premier plan (`scenePhase`), et après la passe
  d'ingestion locale que `CompanionApp` déclenche à l'ouverture
  (`SyncEngine.ingestLocalData()` — aucune requête vers le Mac, donc ni
  découverte Bonjour ni timeout réseau à subir sur ce chemin). Le calcul
  lui-même (fenêtres, score de forme, tendance VO2max, charge
  d'entraînement) est une fonction pure partagée avec l'Accueil macOS —
  `HealthCheckShared/Analysis/WellnessOrchestrator.swift`, appelée par
  `CompanionAdvisorViewModel.refresh()` et par
  `DashboardViewModel.loadWellness()` — pour que les deux cibles ne
  divergent jamais silencieusement ; seuls le poids et les insights
  d'activité restent propres au Mac. Contrairement aux view models
  macOS, `refresh()` est `async` et exécute ses lectures GRDB hors du
  `MainActor` (`Task.detached`) : sur l'iPhone elles partagent la base
  avec l'import HealthKit et peuvent attendre son verrou d'écriture
  plusieurs secondes. Seule l'application du résultat revient sur le
  `MainActor`, et un compteur de génération jette le résultat qu'un
  `refresh()` plus récent a rendu périmé. Réglages (`CompanionSyncView`)
  porte la section d'appairage (saisie du code à 6 chiffres) tant que non
  appairé, puis la section de synchro (date de dernière synchro, résumé du
  rapport, bouton « Envoyer au Mac ») et le dépairage une fois appairé —
  et plus rien d'autre depuis le SP3. `CompanionViewModel` reste l'unique
  porteur d'état pour l'appairage comme pour le plan en cache, entièrement
  injecté par protocole (`Syncing`/`Pairing`) pour se tester sans HealthKit
  ni réseau ; c'est ce qui a rendu le déplacement du plan sûr, ses tests
  portant sur le view model et non sur l'écran qui l'affiche.

## Structure de l'interface

`NavigationSplitView` à 9 sections (Accueil, Sommeil, Effort, Séances,
Entraînement, Corps, Corrélations, Tendances, Données). Un ViewModel
par section, tous `@MainActor`, injectés dans `HealthCheckApp`.

**Chargement unique** : chaque ViewModel expose `hasLoaded` ; les vues
chargent à la première visite seulement. Le rafraîchissement passe
exclusivement par trois `onChange` dans `ContentView` : fin d'import,
`syncGeneration` Withings et `syncGeneration` compagnon. Tout nouveau
ViewModel doit suivre ce motif.

**Règles graphiques** : jamais d'`AreaMark` ancrée à 0 pour des
grandeurs à faible amplitude relative (poids) — plancher à min − 8 %
de l'amplitude plus `includesZero: false`. Le Sankey est dessiné
maison (rubans de Bézier, barres de nœuds, épaisseur ∝ kg) — Swift
Charts n'en a pas.

**Langue.** Deux mécanismes distincts, à ne pas confondre :

- `CFBundleDevelopmentRegion: fr` (littéral dans `project.yml`, pas
  `$(DEVELOPMENT_LANGUAGE)`) pilote les **menus système** d'AppKit —
  l'environnement SwiftUI ne peut rien pour eux.
- `.environment(\.locale, Locale(identifier: "fr_FR"))` sur la `Scene`
  pilote tout ce que SwiftUI formate, **axes Swift Charts compris** :
  sans lui les axes affichaient « Jun/Jul/Aug » au milieu d'une
  interface française.

Les `Locale(identifier: "fr_FR")` posés site par site sur certains
`formatted()` sont depuis redondants — conservés, mais inutiles pour
de nouveaux appels.

## Tests

Mac : 169 cas XCTest, moteurs d'abord : formules de score au 0,01
près, sémantique du résolveur, idempotence du dédoublonnage sur un
vrai store `:memory:`, mapping Withings sur JSON de fixture, parsing
du callback OAuth, parsing GPX, refus de traversée de chemin, ancrage
des deltas sur la dernière pesée, synchro compagnon (fenêtre/
tentatives d'appairage, persistance du jeton, parsing HTTP, codes de
statut du routeur, ingestion idempotente des batchs, auto-cicatrisation
GPX), plan d'entraînement/rapprochement/moniteur de charge/view model
(volumes de plan de référence, rapprochement des séances, alertes
relatives au plan vs. ACWR brut, couverture de la fenêtre d'historique).
L'UI se vérifie visuellement (Swift Charts est invisible pour
l'outillage d'accessibilité) ; les vues de l'écran Entraînement restent
minces et non testées comme tous les autres écrans, seul le view model
est couvert.

iOS (`HealthCheckCompanion`) : 64 cas XCTest — mapping HealthKit avec
unités épinglées, persistance des ancres/du trousseau, découpage en
batchs et avancement des ancres conditionné à l'ack du moteur de
synchro, stub HTTP du client Mac (mémorisation/invalidation/rattrapage
de l'endpoint, requête authentifiée sans jeton), formatage d'hôte URL
IPv4/IPv6/`.name` de `BonjourEndpointProvider`, fusion des réveils
concurrents (`SyncCoalescer`), aller-retour du protocole partagé, le
view model compagnon (appairage, synchro complète/partielle/en échec,
états d'erreur), et le view model de conseils (`CompanionAdvisorViewModel`
— forme/conseil du jour/tendance VO2max calculés depuis le store local,
magasin indisponible, absence de données, et isolation stricte du poids
même quand des données de poids existent en local). Voir la répartition
simulateur/appareil ci-dessus — la découverte Bonjour et la livraison en
arrière-plan sont réservées à l'appareil.

`xcodegen generate` est obligatoire après tout ajout/retrait de
fichier — un pbxproj périmé produit des erreurs « cannot find in
scope » trompeuses ou des runs de tests vides.

## Release

`Scripts/release.sh` : build Release non signé → staging `ditto
--norsrc --noextattr --noacl` (les xattrs cassent `codesign`) →
signature Developer ID avec Hardened Runtime (serveur de timestamp
retenté ×5) → DMG (UDZO, alias /Applications) dans `release/` →
`notarytool submit --wait` (profil trousseau `AppliMacVincentGithub`)
→ staple → vérification `spctl`. La v1.0.0 est sortie ainsi (statut
Accepted).

## Journal des décisions

| Décision | Pourquoi |
|---|---|
| L'import zip manuel reste le chemin principal ; récepteur compagnon Mac ET app compagnon iOS tous deux livrés, validation sur appareil en attente | usage personnel informel ; les deux côtés (listener/appairage/ingestion côté Mac, lecture HealthKit + UI de synchro côté iOS) sont finis et testés unitairement, mais le chemin pair-à-pair (Bonjour sur un vrai réseau, livraison en arrière-plan) n'a pas encore été exercé sur un iPhone physique |
| SQLite/GRDB plutôt que SwiftData | insertions bulk de 1,8 M de lignes mesurées sur l'export réel |
| Résolution de source à la lecture | donnée brute préservée pour les analyses futures |
| Sommeil dans sa propre table catégorielle | la valeur est une phase, pas un nombre |
| API Withings plutôt qu'export CSV | fraîcheur en direct + les quatre métriques absentes de HealthKit + zéro geste manuel |
| Eau hors de l'arbre du Sankey | l'eau corporelle est contenue dans muscle/organes ; en faire un compartiment frère double-compterait |
| ECG (`export_cda.xml`) exclu | format clinique CDA, hors des quatre axes d'analyse |
| Plan/progression/évaluation d'entraînement recalculés à chaque `load()`, rien persisté | l'écran ne peut jamais diverger de ce que produirait un appel direct à `TrainingPlanner`/`SessionMatcher`/`TrainingLoadMonitor` pour le même historique |
| Une seule définition de « semaine » : `TrainingPlanner.monday`, indépendante de `firstWeekday` | `dateInterval(of: .weekOfYear,)` suit la région de la machine : hors locale à semaine-au-lundi, la même sortie du dimanche tombait dans deux semaines différentes alors que l'app dit « cette semaine » aux deux endroits |
| `durationMinutes` renvoie `Double?` au lieu de supposer des minutes | une unité inconnue injectait une distance inventée dans la base d'ancrage du plan ; ne jamais produire un nombre à partir d'une entrée qu'on ne comprend pas |
| Plan ancré sur `goal.createdAt`, cibles reportées de proche en proche | une grandeur recalculée depuis `today` fait bouger le plan chaque jour, effondre le relâchement et rend l'alerte de surdosage inatteignable ; en contrepartie, recréer un objectif repart de zéro |
| Cibles de dénivelé prescrites mais jamais vérifiées | aucune donnée d'altitude n'existe nulle part dans le pipeline (import, synchro compagnon, ou modèle `Workout`) pour les contrôler |
