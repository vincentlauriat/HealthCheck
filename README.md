# HealthCheck

![Release](https://img.shields.io/github/v/release/vincentlauriat/HealthCheck)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![Tests](https://img.shields.io/badge/tests-106%2F106-brightgreen)

Application macOS native (SwiftUI) d'analyse de santé personnelle :
elle importe l'export Apple Santé, lit l'API Withings en direct, et
produit des analyses de niveau Withings/Bevel — scores composites,
piliers dédiés, corrélations — entièrement en local, sans aucun cloud
tiers.

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Installation](#installation)
- [Sources de données](#sources-de-données)
- [Compiler depuis les sources](#compiler-depuis-les-sources)
- [Tests](#tests)
- [Release](#release)
- [Arborescence du projet](#arborescence-du-projet)
- [Documentation](#documentation)
- [Confidentialité](#confidentialité)
- [Roadmap](#roadmap)

## Fonctionnalités

L'app est organisée en huit sections :

| Section | Contenu |
|---|---|
| **Accueil** | Score de forme quotidien 0-100 calculé sur tes baselines personnelles 30 j (sommeil 35 %, FC repos 30 %, HRV 25 %, activité 10 %), observations générées en français, cartes jour/semaine avec deltas honnêtes (comparaison à la même portion écoulée de la semaine précédente). |
| **Sommeil** | Score de nuit 0-100 (durée vs cible 8 h, % profond, % REM, continuité), phases empilées sur 14 nuits, moyennes. |
| **Effort** | Minutes par zone cardiaque Z1-Z5 (bornées sur la FC max réellement observée), score d'effort quotidien pondéré, historique 14 j coloré par intensité. |
| **Séances** | Volume hebdomadaire par activité sur 12 semaines, 25 dernières séances (durée, distance, kcal, FC moyenne), trace GPS dépliable sur carte MapKit. |
| **Corps** | Composition corporelle complète : poids, masses grasse/maigre, muscle, eau, os, graisse viscérale ; deltas 30 j / 1 an ancrés sur la dernière pesée ; diagramme de Sankey de la répartition du poids ; courbes poids/maigre avec bande de graisse. |
| **Corrélations** | 5 questions sur 180 j (ex. « mieux dormir améliore-t-il ta HRV du lendemain ? ») — Pearson avec garde-fous : minimum 10 paires, variance nulle refusée, avertissement corrélation ≠ causalité. |
| **Tendances** | FC repos, poids, VO₂ max, sommeil — aire + moyenne mobile 7 j, périodes 1 sem → tout. |
| **Données** | Import de l'export Apple Santé (bouton ou glisser-déposer), connexion/synchro Withings, et appairage compagnon iPhone (récepteur Mac, réseau local). |

## Installation

Télécharger le DMG signé Developer ID et notarisé Apple depuis les
[releases GitHub](https://github.com/vincentlauriat/HealthCheck/releases),
l'ouvrir et glisser HealthCheck.app dans Applications. Aucun
avertissement Gatekeeper.

## Sources de données

**Export Apple Santé** (obligatoire pour l'historique complet) :
sur iPhone, app Santé → photo de profil → « Exporter toutes les données
de santé » → transférer le `.zip` au Mac (AirDrop, iCloud Drive) → le
déposer sur l'écran Données. L'import est *idempotent* : réimporter le
même export n'insère rien deux fois. Testé à l'échelle réelle : 844 Mo,
1,8 M d'enregistrements, ~10 min.

> macOS n'a **aucun accès HealthKit** (vérifié empiriquement jusqu'à
> macOS 27 beta : le framework se lie mais `isHealthDataAvailable()`
> renvoie `false`). L'export manuel est la seule voie pour les données
> Apple Watch/iPhone.

**API Withings** (optionnelle, recommandée si tu as une balance
Withings) : synchronisation directe du cloud Withings — y compris
muscle, eau, os et graisse viscérale, qui n'existent pas dans
HealthKit et ne seront jamais dans l'export Apple. Auto-synchro au
lancement (au plus une fois par 12 h). Configuration :
[docs/withings-setup.md](docs/withings-setup.md).

**iPhone (compagnon)** — *app iOS livrée (validation sur iPhone en
cours)* : synchronisation directe depuis l'iPhone en réseau local,
sans passer par l'export zip. Le récepteur côté Mac (serveur,
appairage par code à 6 chiffres, ingestion idempotente) et l'app
compagnon iOS (lecture HealthKit, appairage, synchro manuelle et en
arrière-plan) sont tous les deux livrés et testés unitairement ; la
validation sur un iPhone physique reste à faire. Voir
[docs/companion-setup.md](docs/companion-setup.md).

## Compiler depuis les sources

Prérequis : Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/vincentlauriat/HealthCheck.git
cd HealthCheck
xcodegen generate          # obligatoire après tout ajout/retrait de fichier
open HealthCheck.xcodeproj # scheme HealthCheck (macOS) ou HealthCheckCompanion (iOS)
```

La dépendance GRDB (SQLite) est résolue par SPM à la première ouverture.

## Tests

```bash
xcodebuild -scheme HealthCheck -destination 'platform=macOS' test
xcodebuild -scheme HealthCheckCompanion -destination 'platform=iOS Simulator,name=iPhone 17' test
```

106 tests côté Mac, tous sur les moteurs purs (scores, zones,
corrélations, mapping Withings, parsing GPX, dédoublonnage), le store
et la synchro compagnon (appairage, routeur HTTP, ingestion
idempotente). Les moteurs d'analyse sont volontairement découplés de
SwiftUI pour rester testables au centième près. Côté iOS, 41 tests
(mapping HealthKit, ancres, moteur de synchro, client Mac, view
model) ; la découverte Bonjour et la livraison en arrière-plan ne
sont validables que sur appareil (voir
[docs/companion-setup.md](docs/companion-setup.md)).

## Release

```bash
./Scripts/release.sh
```

Pipeline complet : build Release, staging sans xattrs, signature
Developer ID avec Hardened Runtime, DMG dans `release/`, notarisation
Apple (`--wait`), staple, vérification `spctl`. Voir les prérequis
(certificat, profil notarytool) en tête du script.

## Arborescence du projet

```
HealthCheck/
├── HealthCheck/
│   ├── Models/          # HealthRecord, Workout, SleepRecord (+ clés de dédoublonnage)
│   ├── Import/          # Parseur SAX, zip, importeur, GPX, client Withings, serveur compagnon
│   ├── Store/           # HealthStore (SQLite/GRDB), SourcePriorityResolver
│   ├── Analysis/        # Moteurs purs : scores, zones FC, corrélations, Sankey…
│   ├── ViewModels/      # Un par section, @MainActor, chargement unique
│   └── Views/           # SwiftUI + Swift Charts + Sankey maison
├── HealthCheckShared/    # DTO d'échange + protocole compagnon, partagés Mac/iOS
├── HealthCheckTests/    # 106 tests (moteurs + store + mapping + synchro compagnon)
├── Companion/            # App iOS (HealthKit, synchro, appairage, UI)
├── CompanionTests/       # 41 tests (mapping HealthKit, ancres, synchro, view model)
├── Scripts/release.sh   # Release signée + notarisée
├── docs/                # Guides + specs de conception
└── project.yml          # Source de vérité XcodeGen (le .xcodeproj est généré)
```

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — architecture détaillée en
  français ([version anglaise](ARCHITECTURE_EN.md), source de vérité)
- [docs/withings-setup.md](docs/withings-setup.md) — configurer la
  synchro Withings
- [docs/companion-setup.md](docs/companion-setup.md) — installer et
  appairer l'app compagnon iOS
- [docs/superpowers/specs/](docs/superpowers/specs/) — specs de
  conception d'origine (import/dashboard, tendances)

## Confidentialité

Toutes les données restent sur le Mac :
`~/Library/Application Support/HealthCheck/` (base SQLite, traces GPX,
identifiants Withings). Les seules requêtes réseau partent vers l'API
Withings, uniquement si tu connectes ton compte. Rien n'est committé :
les identifiants et jetons vivent hors du dépôt.

## Roadmap

- [x] Spec 1 — import + dédoublonnage + stockage + dashboard quotidien
- [x] Spec 2 — tendances long terme (FC repos, poids, VO2 max, sommeil)
- [x] Score de forme + insights + redesign (passe « niveau Withings/Bevel »)
- [x] Piliers Sommeil (phases, score de nuit) et Effort (zones FC, strain)
- [x] Pilier Corps — composition corporelle + Sankey de répartition
- [x] Synchro API Withings — muscle, eau, os, graisse viscérale en direct
- [x] Spec 3 — écran Séances + traces GPX sur carte MapKit
- [x] Spec 4 — corrélations santé (Pearson sur 180 j, 5 questions)
- [x] Release v1.0.0 signée et notarisée
- [x] (Optionnel) App compagnon iOS pour supprimer l'export manuel — récepteur Mac + app iOS livrés (serveur, appairage, ingestion, lecture HealthKit, synchro manuelle/arrière-plan) ; validation sur iPhone physique restante
