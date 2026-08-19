# Architecture — HealthCheck

Miroir français de `ARCHITECTURE_EN.md` (source de vérité) — à éditer
dans le même tour que la version anglaise.

## Vue d'ensemble

Application macOS native (SwiftUI, macOS 15 Sequoia minimum) qui importe
les données Apple Santé exportées manuellement depuis iOS et produit des
analyses de santé/exercices. Aucun accès HealthKit natif n'existe sur
macOS (même via Mac Catalyst) — vérifié empiriquement (pas d'app Santé
sous `/System/Applications` ni `/Applications`). L'import est donc la
seule voie viable en v1.

## Couches

```
Zip export Santé
      │
      ▼
┌─────────────┐   HealthDataSource    ┌─────────────┐        ┌──────────────┐
│  Importer   │ ─────protocole──────► │    Store    │ ◄────► │  Dashboard   │
│ (zip+parse) │                       │  (SQLite)   │        │  (SwiftUI)   │
└─────────────┘                       └─────────────┘        └──────────────┘
```

- **Importer** : extrait le `.zip`, parse `export.xml` en streaming SAX
  (`XMLParser`), ne charge jamais le fichier complet (844 Mo+) en DOM. Les
  types/attributs XML inconnus sont ignorés, pas fatals — Apple modifie ce
  schéma d'une version d'iOS à l'autre sans préavis.
- **Store** : SQLite via GRDB, transactions batchées (~5000 lignes/tx).
  Choisi plutôt que SwiftData/Core Data après mesure de l'export réel de
  l'utilisateur (844 Mo, 1,8M `<Record>`) — l'insertion bulk à cette
  échelle est un risque de performance/fiabilité sur un store géré. Clé
  primaire synthétique (hash type+source+device+dates+valeur+unité,
  Apple ne fournissant aucun ID stable) rend le ré-import idempotent
  (`INSERT OR IGNORE`).
- **Dashboard** : SwiftUI + Swift Charts, lit via une couche de résolution
  de priorité de source (Watch > iPhone pour les métriques mesurées en
  continu) pour éviter le double comptage d'échantillons qui se
  chevauchent — la donnée brute reste intacte en base pour les specs
  futures.

## Volumes de données (mesurés, export utilisateur du 2026-08-19)

- `export.xml` : 844 Mo, 1 806 362 `<Record>`, 23 672 `<Workout>`
- `export_cda.xml` (ECG, format CDA) : 482 Mo — hors périmètre
- `workout-routes/` : 413 fichiers GPX
- Total dézippé : ~1,5 Go

## Point d'extension

L'import passe par un protocole `HealthDataSource`. Aujourd'hui implémenté
par le lecteur de fichier zip ; une future app compagnon iOS + flux
CloudKit pourrait implémenter le même protocole sans toucher au Store ni
à l'UI. Non construit en v1 — délibérément différé.

## Feuille de route des specs

1. Import + dédoublonnage + stockage + dashboard quotidien (en cours)
2. Tendances long terme
3. Suivi d'entraînement détaillé (+ traces GPX)
4. Corrélations santé croisées
