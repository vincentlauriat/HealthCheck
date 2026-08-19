# HealthCheck — Spec 2 : Tendances long terme

Date : 2026-08-19
Statut : approuvé, en attente de plan d'implémentation

## Contexte

Spec 1 (import + dashboard quotidien/hebdomadaire) est terminée, fusionnée
dans `main`, et vérifiée à l'échelle réelle. Cette spec ajoute la
deuxième famille d'analyses demandée : les tendances long terme sur
quatre métriques — fréquence cardiaque au repos, poids, VO2 max,
sommeil — visualisées en graphiques sur une période sélectionnable.

## Données de référence (export réel, mesuré le 2026-08-19)

- `HKQuantityTypeIdentifierRestingHeartRate` : 811 enregistrements
- `HKQuantityTypeIdentifierBodyMass` (poids) : 3 961 enregistrements
- `HKQuantityTypeIdentifierVO2Max` : 384 enregistrements
- `HKCategoryTypeIdentifierSleepAnalysis` (sommeil) : 2 910 enregistrements

Ces quatre métriques sont naturellement peu fréquentes (au plus quelques
échantillons par jour), contrairement aux pas/calories de la Spec 1. Même
sur plusieurs années d'historique, le volume par métrique reste de
l'ordre de quelques milliers de points.

## Décision d'architecture : pas d'agrégation SQL

Le pipeline de lecture de la Spec 1 (`HealthStore.records(type:from:to:)`
puis `SourcePriorityResolver.resolve(_:)` en mémoire) est réutilisé tel
quel. Vu les volumes mesurés ci-dessus, une agrégation `GROUP BY` côté
SQL serait une optimisation prématurée : le nombre de lignes à charger et
résoudre en mémoire pour n'importe laquelle de ces quatre métriques, même
sur « Tout » l'historique, reste dans les milliers — négligeable pour le
matériel visé. Garder un seul chemin de lecture pour toute l'app
(résolution de priorité de source à la lecture, jamais au stockage)
reste la priorité architecturale, comme établi en Spec 1.

## Le cas particulier du sommeil

`HKCategoryTypeIdentifierSleepAnalysis` est un type **catégoriel** :
l'attribut `value` du XML est une chaîne (ex.
`HKCategoryValueSleepAnalysisAsleepCore`), pas un nombre. Le parseur de
la Spec 1 (`HealthExportParser`) l'ignore délibérément — le guard
`Double(valueString)` échoue systématiquement sur ces enregistrements et
les fait tomber dans le chemin « type/attribut inconnu, ignoré ».

Cette spec ajoute :

- **Modèle `SleepRecord`** : même structure que `HealthRecord` (type,
  sourceName, device, unit, startDate, endDate, creationDate) mais avec
  `value: String` au lieu de `Double`, et la même stratégie de clé de
  dédoublonnage synthétique (SHA256 des champs pertinents).
- **Table `sleep_record`** (nouvelle, séparée de `health_record`) —
  colonne `value` en `TEXT` plutôt que `REAL`.
- **Extension du parseur** : `HealthExportParser.parse` gagne un
  troisième callback `onSleepRecord: (SleepRecord) -> Void`, déclenché
  sur les éléments `<Record type="HKCategoryTypeIdentifierSleepAnalysis"
  ...>`. Les autres types catégoriels restent ignorés (hors périmètre).
- **Calcul de la durée de sommeil par nuit** : somme des intervalles
  `[startDate, endDate]` dont `value` commence par
  `HKCategoryValueSleepAnalysisAsleep` (couvre `AsleepCore`,
  `AsleepDeep`, `AsleepREM`, `AsleepUnspecified` — toutes les
  sous-catégories de la taxonomie watchOS 9+ et l'ancienne valeur unique
  `Asleep` des versions antérieures), en excluant explicitement `InBed`
  et `Awake`. Pas de répartition par phase en v1 — juste une durée
  totale.
- **Regroupement par nuit** : une nuit est identifiée par le jour
  calendaire de `startDate - 12h` (pas `startDate` brut), pour qu'une
  session commençant à 23h et finissant à 7h ne soit pas coupée entre
  deux jours calendaires.

## Composants

### `TrendsViewModel`

`@MainActor ObservableObject` qui, pour une période sélectionnée (3
mois / 6 mois / 1 an / tout), interroge `HealthStore` pour les 4
métriques, applique `SourcePriorityResolver.resolve(_:)`, puis regroupe
par jour (par nuit pour le sommeil) pour produire une série de points
`(Date, Double)` par métrique. Réutilise le même store et le même
résolveur que `DashboardViewModel`.

### `TrendsView`

Sélecteur de période (segmented control) + 4 graphiques Swift Charts
(`LineMark`), un par métrique : FC repos (bpm), poids (kg), VO2 max
(ml/kg/min), sommeil (heures/nuit).

### Navigation

La sidebar de `ContentView` (actuellement un item statique « Dashboard »
sans sélection fonctionnelle depuis la Spec 1) devient une vraie
sélection à deux entrées : Dashboard / Tendances.

## Hors périmètre (explicitement)

- Répartition du sommeil par phase (Core/Deep/REM)
- Corrélations entre métriques (Spec 4)
- Export ou partage des graphiques
- Sélecteur de plage de dates libre (seulement des périodes fixes en v1)
- Agrégation SQL côté base (réévaluer seulement si une future métrique à
  très haute fréquence rejoint cette vue)
