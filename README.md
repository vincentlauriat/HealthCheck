# HealthCheck

Application macOS native qui importe les données Apple Santé (export
manuel depuis iOS) pour produire des analyses de santé et d'exercices.

## État du projet

Spec 1 implémentée et fusionnée dans `main` : import de l'export Apple
Santé, dédoublonnage par priorité de source, stockage SQLite, dashboard
jour/semaine. Voir `MEMORY.md` pour l'état détaillé et `TODOS.md` pour la
liste des tâches.

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
- [ ] Spec 2 — tendances long terme
- [ ] Spec 3 — suivi d'entraînement détaillé
- [ ] Spec 4 — corrélations santé
