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
                                            Vues SwiftUI (8 sections)
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

## Structure de l'interface

`NavigationSplitView` à 8 sections (Accueil, Sommeil, Effort, Séances,
Corps, Corrélations, Tendances, Données). Un ViewModel par section,
tous `@MainActor`, injectés dans `HealthCheckApp`.

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

105 cas XCTest, moteurs d'abord : formules de score au 0,01 près,
sémantique du résolveur, idempotence du dédoublonnage sur un vrai
store `:memory:`, mapping Withings sur JSON de fixture, parsing du
callback OAuth, parsing GPX, refus de traversée de chemin, ancrage des
deltas sur la dernière pesée, synchro compagnon (fenêtre/tentatives
d'appairage, persistance du jeton, parsing HTTP, codes de statut du
routeur, ingestion idempotente des batchs, auto-cicatrisation GPX).
L'UI se vérifie visuellement (Swift Charts est invisible pour
l'outillage d'accessibilité).

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
| L'import zip manuel reste le chemin principal ; récepteur compagnon Mac livré, client iOS pas encore construit | usage personnel informel ; le côté Mac (listener, appairage, ingestion) est fait, l'app iOS est un chantier séparé pas encore démarré |
| SQLite/GRDB plutôt que SwiftData | insertions bulk de 1,8 M de lignes mesurées sur l'export réel |
| Résolution de source à la lecture | donnée brute préservée pour les analyses futures |
| Sommeil dans sa propre table catégorielle | la valeur est une phase, pas un nombre |
| API Withings plutôt qu'export CSV | fraîcheur en direct + les quatre métriques absentes de HealthKit + zéro geste manuel |
| Eau hors de l'arbre du Sankey | l'eau corporelle est contenue dans muscle/organes ; en faire un compartiment frère double-compterait |
| ECG (`export_cda.xml`) exclu | format clinique CDA, hors des quatre axes d'analyse |
