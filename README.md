# HealthCheck

Application macOS native qui importe les données Apple Santé (export
manuel depuis iOS) pour produire des analyses de santé et d'exercices.

## État du projet

Specs 1 et 2 fusionnées dans `main`, puis deux passes « niveau
Withings/Bevel » : import de l'export Apple Santé (dédoublonnage,
SQLite), score de forme quotidien 0-100 sur baselines personnelles,
observations générées en français, pilier **Sommeil** (score de nuit,
phases profond/REM/léger sur 14 nuits), pilier **Effort** (zones
cardiaques Z1-Z5 depuis la FC continue, score d'effort, historique
14 j), tendances long terme. Navigation en 5 sections : Accueil,
Sommeil, Effort, Tendances, Données. Voir `MEMORY.md` pour l'état
détaillé et `TODOS.md` pour la liste des tâches.

## Lancer le projet

```bash
xcodegen generate
open HealthCheck.xcodeproj   # scheme HealthCheck
```

## Pourquoi un import manuel ?

macOS n'a pas d'accès natif à HealthKit (même via Mac Catalyst). Le seul
moyen d'obtenir les données Apple Santé sur ce Mac est l'export manuel
depuis l'app Santé iOS (icône profil → « Exporter toutes les données de
santé »), transféré ensuite au Mac. Voir `ARCHITECTURE.md` pour le détail.

## Roadmap

- [x] Spec 1 — import + dédoublonnage + stockage + dashboard quotidien
- [x] Spec 2 — tendances long terme (FC repos, poids, VO2 max, sommeil)
- [x] Score de forme + insights + redesign (passe « niveau Withings/Bevel »)
- [x] Piliers Sommeil (phases, score de nuit) et Effort (zones FC, strain)
- [x] Pilier Corps — composition corporelle (poids, graisse, maigre, IMC)
- [x] Synchro API Withings — muscle, eau, os, graisse viscérale en direct
- [x] Spec 3 (phase 1) — écran Séances : volume hebdo, dernières séances
- [x] Spec 3 (phase 2) — traces GPX des séances sur carte MapKit
- [ ] Spec 4 — corrélations santé
