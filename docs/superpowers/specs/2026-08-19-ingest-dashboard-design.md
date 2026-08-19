# HealthCheck — Spec 1 : Pipeline d'import + Dashboard quotidien

Date : 2026-08-19
Statut : en attente de revue utilisateur

## Contexte

HealthCheck est une application macOS native destinée à un usage informel
(l'utilisateur, éventuellement quelques proches — pas de diffusion App
Store) qui lit les données Apple Santé pour produire des analyses de santé
et d'exercices. Le projet est découpé en 4 specs successives ; cette spec
couvre le socle commun : import des données, dédoublonnage, stockage, et
un premier dashboard quotidien qui prouve le pipeline de bout en bout.

Les specs suivantes (tendances long terme, suivi d'entraînement détaillé,
corrélations santé) s'appuieront sur le même stockage sans le modifier.

## Contrainte technique fondatrice

macOS n'expose aucun store HealthKit local (pas d'app Santé sur macOS, et
HealthKit n'est pas disponible via Mac Catalyst). Il n'existe donc aucun
accès natif ou automatique aux données Apple Santé depuis un Mac.

La seule voie réaliste en v1 est l'**export manuel** depuis l'app Santé
iOS (icône profil → « Exporter toutes les données de santé »), transféré
ensuite sur le Mac par l'utilisateur (AirDrop / iCloud Drive), puis importé
dans HealthCheck. Une synchronisation quasi automatique (app compagnon iOS
+ CloudKit) est une évolution possible mais explicitement hors périmètre
de cette spec — le pipeline d'import est conçu comme une brique isolée
(protocole `HealthDataSource`) pour permettre ce remplacement plus tard
sans toucher au stockage ni à l'UI.

## Données de référence (export réel mesuré le 2026-08-19)

- `export.xml` : 844 Mo, 1 806 362 éléments `<Record>`, 23 672 `<Workout>`
- `export_cda.xml` (ECG, format CDA clinique) : 482 Mo — **hors périmètre**,
  aucune des 4 familles d'analyses visées n'en a besoin
- `workout-routes/` : 413 fichiers GPX (traces GPS des séances)
- Total dézippé : ~1,5 Go

Ces volumes excluent tout parsing DOM en mémoire et tout stockage géré à
haut risque de performance sur l'insertion en masse.

## Architecture

Application macOS native SwiftUI (macOS 15 Sequoia minimum), 3 couches
isolées communiquant par interfaces bien définies :

```
Zip export Santé
      │
      ▼
┌─────────────┐   HealthDataSource    ┌─────────────┐        ┌──────────────┐
│  Importer   │ ─────protocole──────► │    Store    │ ◄────► │  Dashboard   │
│ (zip+parse) │                       │  (SQLite)   │        │  (SwiftUI)   │
└─────────────┘                       └─────────────┘        └──────────────┘
```

### Importer

- Extraction du `.zip` (ou dossier déjà dézippé) dans un dossier temporaire
- Validation basique : présence d'`export.xml`
- Parsing **streaming SAX** via `XMLParser` (Foundation) — jamais de DOM
  complet en mémoire vu la taille du fichier
- Chaque `<Record>` / `<Workout>` est transformé en struct Swift
  intermédiaire
- Les types d'enregistrement ou attributs XML inconnus sont **ignorés
  silencieusement** (Apple modifie ce schéma sans préavis entre versions
  d'iOS — le parseur ne doit jamais planter dessus, seulement journaliser
  en interne)
- Les fichiers GPX de `workout-routes/` sont associés à leur `Workout`
  correspondant et importés séparément

### Store

- **SQLite via GRDB**, pas SwiftData ni Core Data — à l'échelle de 1,8M+
  lignes, l'insertion bulk sur un store géré est un risque de performance
  et de fiabilité non nécessaire ; SQLite avec transactions batchées est
  prévisible et éprouvé
- Écriture par lots (ex. 5000 lignes / transaction)
- Table `health_records`, clé primaire **synthétique** :
  `hash(type, sourceName, device, startDate, endDate, value, unit)` —
  Apple ne fournit aucun identifiant stable dans le XML
- Import idempotent : `INSERT OR IGNORE` sur cette clé. Un ré-import du
  même export (ou d'un export ultérieur qui recontient tout l'historique,
  comme le fait toujours l'app Santé) n'insère que les enregistrements
  réellement nouveaux
- Les données brutes (non résolues) sont conservées telles quelles ; la
  résolution de priorité de source (voir ci-dessous) se fait **à la
  lecture**, pas au stockage, pour rester disponible aux specs futures qui
  pourraient avoir besoin de la donnée brute

### Dédoublonnage par priorité de source (lecture)

iPhone et Apple Watch écrivent tous deux des échantillons qui se
chevauchent pour un même type de mesure (ex. les pas). Le fichier XML brut
ne les dédoublonne pas — les sommer directement fausserait silencieusement
les totaux. À la lecture, une résolution par bucket temporel applique une
priorité de source (Watch > iPhone pour les métriques que la Watch mesure
en continu), reproduisant le comportement de l'app Santé à l'affichage.
Ce composant est un élément nommé du design, pas un détail d'implémentation
secondaire — il conditionne la fiabilité de toutes les analyses futures.

### Dashboard (UI)

Vue d'ensemble du jour et de la semaine en cours : pas, distance, calories
actives, minutes d'exercice, dernière fréquence cardiaque au repos connue.
Toutes les métriques passent par la résolution de priorité de source.

### Flux d'import (UX)

1. Déclenchement par bouton « Importer » (sélecteur de fichier) **ou**
   glisser-déposer du `.zip` sur la fenêtre — les deux sont supportés dès
   la v1
2. Extraction + validation
3. Parsing avec barre de progression (compteur d'enregistrements vus /
   temps écoulé — la taille totale exacte n'est pas connue à l'avance en
   SAX)
4. Import batché en base, compteur enregistrements ajoutés vs déjà connus
5. Résumé final : nombre total traité, nombre de nouveaux enregistrements

## Gestion d'erreurs

- Zip corrompu ou incomplet → message clair à l'utilisateur, pas de crash
- Élément XML inattendu → ignoré, journalisé en interne, parsing continue
- Import interrompu (app fermée en cours de route) → les transactions déjà
  commitées restent valides ; pas de rollback global nécessaire grâce à
  l'idempotence de la clé synthétique

## Tests

- Parser testé sur une fixture réduite représentative (pas les 844 Mo
  réels en CI)
- Dédoublonnage testé avec des enregistrements volontairement dupliqués/
  qui se chevauchent entre sources (iPhone + Watch, même intervalle)
- Ré-import du même fichier → zéro nouveau record inséré (idempotence)

## Hors périmètre (explicitement)

- Synchronisation automatique / temps réel (app compagnon iOS + CloudKit)
- Données ECG (`export_cda.xml`)
- Tendances long terme, analyse détaillée d'entraînement, corrélations
  (specs 2 à 4, sur le même stockage)
- Diffusion App Store (signature/notarisation DMG couvertes par le skill
  `macos-app-release` en fin de cycle, hors scope de cette spec)
