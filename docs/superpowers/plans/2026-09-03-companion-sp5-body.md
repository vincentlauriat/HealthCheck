# Companion SP5 — Corps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** l'iPhone lit le poids, la masse grasse et la masse maigre depuis
HealthKit pour son propre écran Corps, sans jamais les pousser vers le Mac.

**Architecture:** trois changements. `HKMapper` apprend les trois types
corporels ; `SyncEngine` reçoit une **seconde liste** de types que seule la
passe locale consomme ; `BodyViewModel` est remonté dans le partagé, comme le
SP1 l'a fait pour les sept autres. La vue reste propre à iOS.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Charts, HealthKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-companion-full-analysis-design.md`
(§6 « Weight: read from HealthKit, never pushed », §8 pour la garde attendue).

## Global Constraints

- Interface et messages utilisateur en **français**, accents complets.
  Identifiants, commits et fichiers de doc en **anglais**.
- Toute garde doit avoir été **vue échouer** contre le défaut qu'elle
  surveille, et ne doit pas être satisfiable à vide ni par construction.
- `now` et `calendar` toujours injectés ; jamais de `Date()` dans un test.
- Après ajout de fichier : `xcodegen generate`.
- Tests iOS **sans** `CODE_SIGNING_ALLOWED=NO` ; macOS **avec**.
- Cible de test iOS : `HealthCheckCompanionTests` (le répertoire s'appelle
  `CompanionTests`, la **cible** non — `-only-testing:CompanionTests/…` échoue).
- Simulateur : le démarrer explicitement et cibler son UDID
  (`1BDBE5F2-3C70-450C-B97E-DE48F288CFEA`), jamais le nom.
- Référence avant de commencer : **92 tests iOS**, **287 macOS**.
- Branche `feat/companion-sp5-body`, jamais `main`.

### Les deux pièges de ce sous-projet, vérifiés sur les données réelles

1. **Le libellé d'unité est identifiant.** `HKMapper.record` écrit
   `unit: mapping.label` en base, et depuis le correctif du 2026-09-03 `unit`
   entre dans `DedupKey`. La base contient déjà 7 769 pesées en `kg`, 7 274
   taux de graisse en `%` et 7 388 masses maigres en `kg` : émettre autre
   chose que ces libellés **verbatim** recréerait exactement les doublons
   qu'on vient de supprimer.
2. **Le taux de graisse est une fraction.** Les 7 274 lignes existantes vont
   de 0,03 à 0,4527, pas de 3 à 45 — `WithingsMapper` le ramène en fraction
   « comme dans l'export Apple Santé ». `HKUnit.percent()` rend la même
   échelle ; c'est ce qui doit être épinglé, et une garde le vérifie.

---

### Task 1: Ingérer les types corporels localement, jamais vers le Mac

**Files:**
- Modify: `Companion/Sync/HKMapper.swift`
- Modify: `Companion/Sync/SyncEngine.swift`
- Modify: `CompanionTests/HKMapperTests.swift` (réécrire
  `test_unknownQuantityType_isDropped`)
- Create: `CompanionTests/LocalOnlyTypesTests.swift`

**Interfaces:**
- Produces: `SyncEngine.localOnlyTypes: [String]` et le paramètre
  `localOnlyTypeIdentifiers` de `SyncEngine.init`.

- [ ] **Step 1: Apprendre les trois types à `HKMapper`**

Dans `quantityUnits`, après `vo2Max` — libellés verbatim, cf. piège 1 :

```swift
        HKQuantityTypeIdentifier.bodyMass.rawValue: (.gramUnit(with: .kilo), "kg"),
        HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: (.percent(), "%"),
        HKQuantityTypeIdentifier.leanBodyMass.rawValue: (.gramUnit(with: .kilo), "kg")
```

`readTypes` dérive de `quantityUnits.keys` : iOS redemandera l'autorisation
au prochain lancement, sans autre changement.

- [ ] **Step 2: Réécrire le test qui utilisait `bodyMass` comme exemple**

`test_unknownQuantityType_isDropped` prenait `bodyMass` pour « type ignoré » :
c'est précisément ce qui change. Le remplacer par un type que le mapper
n'ingère pas et n'ingérera pas — la température corporelle — et ajouter les
deux gardes d'échelle du piège 2 :

```swift
    func test_unknownQuantityType_isDropped() {
        // La température corporelle n'est lue par aucun écran : elle reste
        // l'exemple d'un type hors périmètre. `bodyMass` ne l'est plus (SP5).
        let sample = quantitySample(.bodyTemperature, unit: .degreeCelsius(), value: 36.8, duration: 0)
        XCTAssertNil(HKMapper.record(from: sample))
    }

    func test_bodyFatPercentage_isMappedAsAFraction() throws {
        // Les 7 274 lignes déjà en base vont de 0,03 à 0,4527 : une échelle
        // 0-100 ferait diverger l'iPhone du Mac sur le même écran.
        let sample = quantitySample(.bodyFatPercentage, unit: .percent(), value: 0.253, duration: 0)
        let record = try XCTUnwrap(HKMapper.record(from: sample))
        XCTAssertEqual(record.value, 0.253, accuracy: 0.0001)
        XCTAssertEqual(record.unit, "%", "le libellé entre dans DedupKey : il doit être celui déjà en base")
    }

    func test_bodyMass_isMappedInKilograms() throws {
        let sample = quantitySample(.bodyMass, unit: .gramUnit(with: .kilo), value: 88.5, duration: 0)
        let record = try XCTUnwrap(HKMapper.record(from: sample))
        XCTAssertEqual(record.value, 88.5, accuracy: 0.0001)
        XCTAssertEqual(record.unit, "kg")
    }
```

- [ ] **Step 3: La seconde liste de types dans `SyncEngine`**

```swift
    /// Types lus pour l'iPhone seul et **jamais poussés**. Le Mac possède déjà
    /// ces mesures via l'API Withings, sous d'autres identifiants de source ;
    /// les pesées ayant une durée nulle, `SourcePriorityResolver` ne les
    /// dédoublonne pas (suivi M2) et les pousser créerait de vrais doublons.
    static let localOnlyTypes: [String] = [
        HKQuantityTypeIdentifier.bodyMass.rawValue,
        HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
        HKQuantityTypeIdentifier.leanBodyMass.rawValue
    ]
```

Nouveau paramètre d'init `localOnlyTypeIdentifiers: [String] = SyncEngine.localOnlyTypes`,
stocké dans une propriété du même nom.

**Les deux passes doivent l'ingérer, une seule doit l'ignorer.** Dans
`ingestLocalData()`, boucler sur `typeIdentifiers + localOnlyTypeIdentifiers`.
Dans `syncAll()`, ajouter **avant** la boucle existante :

```swift
        // Ingérés ici aussi : sans cette boucle, « Envoyer au Mac » sauterait
        // silencieusement le poids, puisque syncAll() est l'autre chemin qui
        // alimente la base locale. Le push, lui, ne voit que typeIdentifiers.
        for type in localOnlyTypeIdentifiers {
            await ingestLocally(type)
        }
```

- [ ] **Step 4: La garde, sur le chemin de push et non sur la liste**

`CompanionTests/LocalOnlyTypesTests.swift`. Une garde qui comparerait les deux
listes serait vraie par construction ; celle-ci observe ce qui atteint le
pousseur.

```swift
import XCTest
@testable import HealthCheckCompanion

/// Le poids est lu pour l'iPhone et ne doit jamais partir vers le Mac, qui
/// tient les mêmes mesures de Withings sous d'autres identifiants (spec §6).
final class LocalOnlyTypesTests: XCTestCase {
    /// Pousseur espion : retient tout ce qui lui est soumis.
    private actor SpyPusher: BatchPushing {
        private(set) var batches: [ExchangeBatch] = []
        func push(batch: ExchangeBatch) async throws -> Int {
            batches.append(batch)
            return batch.records.count
        }
    }

    func test_syncAll_ingestsBodyTypesLocallyAndPushesNoneOfThem() async throws {
        // …reader stub rendant un échantillon par type demandé,
        // importeur local espion, SpyPusher.
        // Assertions, chacune indispensable :
        //  1. l'importeur local a bien reçu les trois types corporels
        //     (sinon la garde passerait avec une ingestion cassée) ;
        //  2. aucun batch poussé ne contient un type corporel ;
        //  3. les batchs poussés ne sont pas vides — sinon (2) serait vraie
        //     d'un push entièrement en panne.
    }
}
```

Le stub de lecture et l'importeur espion existent peut-être déjà dans
`CompanionTests/` (les suites de `SyncEngine` en utilisent) : les réutiliser
plutôt qu'en écrire d'autres. Vérifier avant d'écrire.

- [ ] **Step 5: Falsifier**

Mutation de la spec : ajouter les trois types à `defaultTypes`. Attendu :
l'assertion 2 tombe (un type corporel apparaît dans un batch poussé).
Seconde mutation : retirer la boucle ajoutée dans `syncAll()`. Attendu :
l'assertion 1 tombe. Restaurer après chacune, **relire le fichier**.

- [ ] **Step 6: Lancer et commiter**

iOS (95 attendus : 92 + 3) et macOS (287, inchangés).

```bash
git add Companion CompanionTests
git commit -m "feat(companion): read body metrics locally without pushing them"
```

---

### Task 2: Partager `BodyViewModel`

**Files:**
- Move: `HealthCheck/ViewModels/BodyViewModel.swift` → `HealthCheckShared/ViewModels/`
- Create: `HealthCheckShared/Models/WithingsMeasureType.swift`
- Modify: `HealthCheck/Import/WithingsModels.swift`

**Interfaces:**
- Produces: `BodyViewModel` visible des deux cibles ; `WithingsMeasureType`.

`BodyViewModel.daily(_:to:)` n'appelle que `DailyAggregator.averages`,
`resolver.resolve` et `store.records` — tous déjà partagés. Seules les quatre
constantes de `WithingsMapper` bloquent le déplacement.

- [ ] **Step 1: Extraire les quatre identifiants**

`HealthCheckShared/Models/WithingsMeasureType.swift` :

```swift
/// Identifiants des mesures Withings sans équivalent HealthKit. Ils vivent
/// dans le partagé parce que `BodyViewModel` les lit en base et qu'il est
/// partagé depuis le SP5 ; le reste de `WithingsMapper` — l'appel `getmeas`
/// et sa conversion — reste macOS avec les modèles de l'API.
enum WithingsMeasureType {
    static let muscleMass = "WithingsMuscleMass"
    static let hydration = "WithingsHydration"
    static let boneMass = "WithingsBoneMass"
    static let visceralFat = "WithingsVisceralFat"
}
```

Dans `WithingsModels.swift`, remplacer les quatre `static let …Type = "…"` par
des alias vers `WithingsMeasureType`, pour ne pas toucher aux appelants ni aux
tests existants :

```swift
    static let muscleMassType = WithingsMeasureType.muscleMass
    static let hydrationType = WithingsMeasureType.hydration
    static let boneMassType = WithingsMeasureType.boneMass
    static let visceralFatType = WithingsMeasureType.visceralFat
```

- [ ] **Step 2: Déplacer le fichier**

`git mv HealthCheck/ViewModels/BodyViewModel.swift HealthCheckShared/ViewModels/`
puis `xcodegen generate`. Les appelants de `WithingsMapper.muscleMassType` dans
`BodyViewModel` deviennent `WithingsMeasureType.muscleMass`.

**Comportement attendu sur iPhone, à écrire et non à découvrir :** les quatre
requêtes Withings rendent des séries vides, donc `latestMuscleMass` et ses
voisins restent `nil`, donc `weightSankey` est `nil` et la composition
corporelle ne s'affiche pas. C'est exactement ce que la spec §6 prévoit.

- [ ] **Step 3: Les deux suites**

macOS (287) est la garde du déplacement : `BodyViewModel` a déjà ses tests
(`HealthCheckTests/BodyViewModelTests.swift`), qui doivent passer **inchangés**.
iOS (95) prouve que la cible compile le fichier déplacé.

- [ ] **Step 4: Commit**

```bash
git add HealthCheck HealthCheckShared
git commit -m "refactor: share BodyViewModel with the companion target"
```

---

### Task 3: Écran Corps iOS

**Files:**
- Rewrite: `Companion/Views/CompanionBodyView.swift`
- Modify: `Companion/CompanionApp.swift`, `Companion/CompanionRootView.swift`
- Create: `CompanionTests/BodyViewModelIOSTests.swift`

- [ ] **Step 1: La garde d'abord**

Ce que l'écran iPhone a de particulier : la dernière pesée peut être bien
plus ancienne que la période affichée. La synchro Withings → Santé est en
panne depuis le 18 juin 2026 (spec §6), donc l'écran doit afficher une date
visible plutôt que de laisser croire à une valeur du jour.

```swift
    func test_latest_isTheMostRecentWeighIn_evenOutsideTheDisplayedPeriod() throws {
        // Pesée unique à J-200, période demandée : 1 mois.
        // `latest` doit la rendre malgré tout — c'est ce qui alimente la
        // mention « Dernière pesée le … » ; `snapshots` peut être vide.
    }
```

- [ ] **Step 2: La vue**

Poids et masse grasse seulement (spec §6 : ni Sankey ni composition sur
iPhone). En tête, la carte de la dernière pesée avec **sa date en clair**,
puis les deltas 30 j / 1 an quand ils existent, puis une courbe de poids sur
la période choisie (`TrendPeriod.companionCases`, partagé au SP4).
Objectif de poids et alerte de sécurité affichés s'ils existent — ils
viennent du `BodyViewModel` partagé, gratuitement.

Chiffres affichés seulement `if let`, jamais de zéro fabriqué : la règle du
SP3, et ici elle compte double, une masse grasse absente n'étant pas une
masse grasse nulle.

- [ ] **Step 3: Câbler**

`bodyViewModel` dans `CompanionApp` (`BodyViewModel(store: advisorStore,
resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))`), transmis
par `CompanionRootView` à `CompanionBodyView`, qui remplace
`CompanionPlaceholderView`.

- [ ] **Step 4: Lancer, falsifier, commiter**

iOS (96), macOS (287). Mutation de la garde : borner la lecture de `latest` à
la période demandée.

---

### Task 4: Documentation et contrôle sur appareil

- [ ] **Step 1: Contrôle à l'écran** — iPhone **déverrouillé**. iOS demandera
  l'autorisation des trois nouveaux types au premier lancement : **tant qu'elle
  n'est pas accordée, l'écran reste vide exactement comme si le SP5 avait
  échoué.** L'accorder d'abord, puis vérifier : l'onglet Corps affiche la
  dernière pesée avec sa date (probablement mi-juin, cf. spec §6), la courbe de
  poids, et la carte Poids de l'écran Tendances n'est plus vide.
- [ ] **Step 2: Vérifier qu'aucun poids n'est parti vers le Mac** — après un
  « Envoyer au Mac », comparer le nombre de lignes `BodyMass` de la base du Mac
  avant et après. Il doit être identique.
- [ ] **Step 3: Doc** — `ARCHITECTURE.md` + `ARCHITECTURE_EN.md` (miroirs, même
  tour), `CHANGES.md`, `TODOS.md`, `PLAN.md`, `COMMANDS.md`. La règle « le poids
  ne transite jamais » doit apparaître dans l'architecture, avec sa raison.

---

## Definition of done

- Les trois types corporels sont lus sur iPhone et **aucun** n'atteint le Mac,
  prouvé par une garde qui observe le pousseur et vue échouer contre la
  mutation « les remettre dans `typeIdentifiers` ».
- L'échelle et le libellé d'unité correspondent aux lignes déjà en base.
- `BodyViewModel` est partagé, ses tests macOS inchangés.
- L'onglet Corps affiche poids, masse grasse et la **date** de la dernière
  pesée ; pas de Sankey, pas de composition corporelle.
- 96 tests iOS, 287 macOS. Documentation à jour, contrôle appareil fait.
