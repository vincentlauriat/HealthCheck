# Companion SP4 — Tendances et Corrélations

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** l'Accueil de l'iPhone ouvre deux sous-écrans — Tendances (quatre
courbes sur une période choisie) et Corrélations (cinq questions et leurs
nuages de points) — honnêtes sur la profondeur d'historique réellement
disponible.

**Architecture:** aucun nouveau calcul. `TrendsViewModel` et
`CorrelationsViewModel` sont déjà partagés depuis le SP1 et déjà testés côté
macOS. Le SP4 apporte trois choses : le sélecteur de période borné à ce que
l'iPhone possède, une mention explicite de la date de la plus ancienne
mesure, et deux vues iOS. `MetricStyle` — l'identité visuelle d'une métrique,
dont le rôle déclaré est que « chaque métrique garde la même couleur partout »
— est remonté dans le partagé plutôt que redécliné en dur côté iOS, comme le
SP2 avait commencé à le faire pour le sommeil.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Charts, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-02-companion-full-analysis-design.md`

**Navigation, tranchée par la spec (§4).** Tendances et Corrélations sont des
**sous-écrans de l'Accueil**, pas des onglets : les cinq onglets sont la
limite au-delà de laquelle iOS empile le reste derrière un menu « Plus ».
C'est la même forme que Séances sous Entraînement, livrée au SP3.

**Le point de conception, tranché ici.** Le Mac possède l'historique depuis
2012 (import zip, API Withings) ; l'iPhone lit HealthKit sur 180 jours
(`HealthKitReaderLive.initialWindowDays`). Les périodes « 1 an » et « Tout »
n'ont donc aucun sens sur iPhone — elles afficheraient une courbe qui
commence brutalement en mars, indiscernable d'un trou dans les données. Deux
mesures, l'une sans l'autre serait insuffisante : le sélecteur s'arrête à
6 mois, **et** l'écran dit depuis quand il a des mesures. La seconde compte
autant que la première — même sur 6 mois, un compte HealthKit récent n'a
que quelques semaines de recul.

## Global Constraints

- Interface et messages utilisateur en **français**, accents complets.
  Identifiants, commits et fichiers de doc en **anglais**.
- Toute garde doit avoir été **vue échouer** contre le défaut qu'elle
  surveille, et ne doit pas pouvoir être satisfaite à vide — une assertion
  « tous les cas respectent X » est vraie d'une collection vide.
- `now` et `calendar` toujours injectés ; jamais de `Date()` dans un test.
- Après ajout de fichier : `xcodegen generate`.
- Tests iOS **sans** `CODE_SIGNING_ALLOWED=NO` ; macOS **avec**.
- Simulateur : le démarrer explicitement et cibler son UDID
  (`xcrun simctl boot 1BDBE5F2-3C70-450C-B97E-DE48F288CFEA`), jamais le nom —
  ce Mac a deux « iPhone 17 » (runtimes 26.5 et 27.0). Toujours `tee` le
  journal complet : `xcodebuild` ne rend pas toujours la main après les
  tests, et le verdict est dans le journal, pas dans le code de retour.
- Référence avant de commencer : **88 tests iOS**, **279 tests macOS**.
- Branche `feat/companion-sp4-trends-correlations`, jamais `main`.
- Symboles vérifiés dans le code, pas supposés : `TrendPeriod` (`oneWeek`,
  `oneMonth`, `threeMonths`, `sixMonths`, `oneYear`, `all`) avec
  `startDate(now:calendar:)` ; `TrendsViewModel.load(period:) throws` et ses
  quatre séries `restingHeartRate`/`weight`/`vo2Max`/`sleepHours` de
  `[TrendPoint]` ; `TrendsViewModel.movingAverage(_:window:)` `nonisolated
  static` ; `CorrelationsViewModel.load() throws`, `cards: [CorrelationCard]`
  (`question`, `xLabel`, `yLabel`, `result`, `reading`),
  `CorrelationsViewModel.windowDays = 180` ; `CorrelationResult` avec `r` et
  `points` (`day`, `x`, `y`) ; `MetricStyle(title:unit:systemImage:tint:)`.

---

### Task 1: Partager MetricStyle et borner le sélecteur de période

**Files:**
- Create: `HealthCheckShared/Views/MetricStyle.swift`
- Modify: `HealthCheck/Views/Theme.swift` (retrait de `MetricStyle`)
- Modify: `HealthCheckShared/ViewModels/TrendsViewModel.swift` (ajout de
  `companionCases` et `label`)
- Create: `CompanionTests/TrendPeriodTests.swift`

**Interfaces:**
- Produces: `MetricStyle` visible des deux cibles ;
  `TrendPeriod.companionCases: [TrendPeriod]` et `TrendPeriod.label: String`.

- [x] **Step 1: Déplacer `MetricStyle`**

Couper les lignes 1-21 de `HealthCheck/Views/Theme.swift` (le commentaire
de doc et la `struct MetricStyle` avec ses neuf constantes statiques) vers
`HealthCheckShared/Views/MetricStyle.swift`, en tête duquel on remet
`import SwiftUI`. Ne rien changer aux valeurs : ce sont les couleurs déjà
affichées sur le Mac, et l'intérêt du déplacement est justement qu'elles
restent identiques. `Theme.swift` garde `MetricCard` et `DeltaBadge`, qui
utilisent AppKit-adjacent et restent macOS.

`HealthCheckShared` est déjà déclaré comme chemin source des **deux** cibles
dans `project.yml` (lignes 50 et 109) : aucun changement de configuration,
seulement `xcodegen generate`.

- [x] **Step 2: Ajouter `companionCases` et `label`**

Dans `HealthCheckShared/ViewModels/TrendsViewModel.swift`, à la fin de
l'`enum TrendPeriod` :

```swift
    /// Libellé du sélecteur, partagé par les deux cibles pour qu'une période
    /// ne s'appelle pas « 6 mois » ici et « Six mois » là.
    var label: String {
        switch self {
        case .oneWeek: return "1 semaine"
        case .oneMonth: return "1 mois"
        case .threeMonths: return "3 mois"
        case .sixMonths: return "6 mois"
        case .oneYear: return "1 an"
        case .all: return "Tout"
        }
    }

    /// Les seules périodes qui ont un sens sur l'iPhone. HealthKit n'y est lu
    /// que sur `HealthKitReaderLive.initialWindowDays` (180 jours) : proposer
    /// « 1 an » afficherait une courbe qui commence brutalement, impossible à
    /// distinguer d'un trou dans les données. Le Mac, lui, garde toutes les
    /// périodes — il possède l'historique depuis 2012.
    static let companionCases: [TrendPeriod] = [.oneWeek, .oneMonth, .threeMonths, .sixMonths]
```

- [x] **Step 3: Écrire la garde**

`CompanionTests/TrendPeriodTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// Le sélecteur de l'iPhone ne doit proposer que des périodes couvertes par
/// la fenêtre HealthKit locale (180 jours).
final class TrendPeriodTests: XCTestCase {
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    func test_companionCases_stayWithinTheLocalHealthKitWindow() {
        let calendar = Calendar.current
        let now = fixedNow
        let floor = calendar.date(byAdding: .day, value: -HealthKitReaderLive.initialWindowDays, to: now)!

        // Sans ces deux assertions, la suivante serait vraie d'une liste vide.
        XCTAssertEqual(TrendPeriod.companionCases.count, 4)
        XCTAssertTrue(TrendPeriod.companionCases.contains(.sixMonths),
                      "la période la plus longue que l'iPhone puisse honorer")

        for period in TrendPeriod.companionCases {
            XCTAssertGreaterThanOrEqual(
                period.startDate(now: now, calendar: calendar), floor,
                "\(period.label) remonte plus loin que les 180 jours lus dans HealthKit"
            )
        }
    }

    func test_everyCompanionCase_hasALabel() {
        for period in TrendPeriod.companionCases {
            XCTAssertFalse(period.label.isEmpty)
        }
    }
}
```

Si `HealthKitReaderLive.initialWindowDays` est `private`, le rendre
`static let` interne (il documente une contrainte que ce test vérifie) ;
s'il n'est pas accessible depuis les tests, écrire `180` avec un commentaire
citant sa ligne source — jamais un nombre nu.

- [x] **Step 4: Lancer**

```bash
xcodegen generate
xcrun simctl boot 1BDBE5F2-3C70-450C-B97E-DE48F288CFEA 2>/dev/null
xcodebuild test -scheme HealthCheckCompanion \
    -destination 'platform=iOS Simulator,id=1BDBE5F2-3C70-450C-B97E-DE48F288CFEA' 2>&1 \
  | tee /tmp/sp4-t1.log | grep -E "error:|Executed 90|BUILD FAILED" | tail -10
```

Attendu : `Executed 90 tests, with 0 failures`.

- [x] **Step 5: Falsifier**

Ajouter `.oneYear` à `companionCases`. Attendu : le premier test échoue deux
fois — sur le compte (5 au lieu de 4) et sur le plancher (« 1 an remonte plus
loin que les 180 jours lus dans HealthKit »). Restaurer, puis **relire le
fichier** dans le même appel que le commit — lancer la restauration ne prouve
pas qu'elle a eu lieu.

- [x] **Step 6: Vérifier que le Mac n'a pas bougé**

```bash
xcodebuild test -scheme HealthCheck -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/sp4-t1-mac.log \
  | grep -E "error:|Executed 279|BUILD FAILED" | tail -5
```

Attendu : `Executed 279 tests, with 0 failures`. C'est la tâche qui déplace
un type utilisé par les vues macOS : si `MetricStyle` n'est plus visible
depuis `HealthCheck/`, la compilation tombe ici et nulle part ailleurs.

- [x] **Step 7: Commit**

```bash
git add HealthCheckShared HealthCheck/Views/Theme.swift CompanionTests
git commit -m "refactor: share MetricStyle and bound the iOS trend period selector"
```

---

### Task 2: Dire depuis quand les mesures existent

**Files:**
- Modify: `HealthCheckShared/ViewModels/TrendsViewModel.swift`
- Create: `CompanionTests/TrendsViewModelIOSTests.swift`

**Interfaces:**
- Produces: `TrendsViewModel.earliestMeasurement: Date?`.

Un graphique qui commence en mars alors que la période demandée est 6 mois ne
doit pas se lire comme un trou. La date de la plus ancienne mesure est la
réponse, et elle se dérive des séries déjà chargées — aucune requête de plus.

- [x] **Step 1: Écrire la garde d'abord**

`CompanionTests/TrendsViewModelIOSTests.swift` :

```swift
import XCTest
@testable import HealthCheckCompanion

/// `earliestMeasurement` alimente la mention « Mesures depuis le … » de
/// l'écran Tendances : sur un compte HealthKit récent, une courbe de 6 mois
/// n'en couvre parfois que trois, et l'écran doit le dire.
@MainActor
final class TrendsViewModelIOSTests: XCTestCase {
    private let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
    private let fixedNow = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
        .addingTimeInterval(20 * 3600)

    private func record(_ type: String, _ value: Double, at date: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: "Watch", device: nil, unit: "count/min",
                     value: value, startDate: date, endDate: date, creationDate: date)
    }

    func test_earliestMeasurement_isTheOldestPointAcrossEverySeries() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = fixedNow
        let oldest = calendar.date(byAdding: .day, value: -100, to: now)!
        let recent = calendar.date(byAdding: .day, value: -10, to: now)!
        // La FC repos est la série la plus courte, la VO2max la plus ancienne :
        // c'est bien la plus ancienne des deux qui doit ressortir.
        try store.insertRecords([
            record("HKQuantityTypeIdentifierRestingHeartRate", 52, at: recent),
            record("HKQuantityTypeIdentifierVO2Max", 48, at: oldest)
        ])

        let viewModel = TrendsViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load(period: .sixMonths)

        let earliest = try XCTUnwrap(viewModel.earliestMeasurement)
        XCTAssertEqual(calendar.startOfDay(for: earliest),
                       calendar.startOfDay(for: oldest),
                       "la mention doit remonter à la plus ancienne mesure, toutes séries confondues")
    }

    func test_earliestMeasurement_withNoDataAtAll_isNil() throws {
        let store = try HealthStore(path: ":memory:")
        let now = fixedNow

        let viewModel = TrendsViewModel(store: store, resolver: resolver, now: { now })
        try viewModel.load(period: .sixMonths)

        XCTAssertNil(viewModel.earliestMeasurement,
                     "sans aucune mesure, il n'y a pas de date à annoncer")
    }
}
```

- [x] **Step 2: Lancer et constater l'échec de compilation**

`earliestMeasurement` n'existe pas encore : la suite ne compile pas. C'est
l'échec attendu à cette étape.

- [x] **Step 3: Implémenter**

Dans `TrendsViewModel`, après les quatre séries publiées :

```swift
    /// Date de la plus ancienne mesure effectivement chargée, toutes séries
    /// confondues. L'écran iOS s'en sert pour dire depuis quand il a des
    /// données : sur 180 jours de fenêtre HealthKit, une courbe peut
    /// légitimement commencer bien après le début de la période demandée, et
    /// ce début abrupt ne doit pas se lire comme un trou.
    var earliestMeasurement: Date? {
        [restingHeartRate, weight, vo2Max, sleepHours]
            .compactMap(\.first?.date)
            .min()
    }
```

Les séries sont déjà triées par date croissante — `dailyAverage` termine par
`.sorted { $0.date < $1.date }` et `SleepAggregator.nightlyHours` rend une
série ordonnée. Vérifier ce second point avant de s'y fier ; sinon prendre
`points.map(\.date).min()` par série.

- [x] **Step 4: Lancer**

Attendu : `Executed 92 tests, with 0 failures`.

- [x] **Step 5: Falsifier**

Deux mutations, chacune sur une assertion :
1. `.min()` → `.max()` : le premier test tombe (il annoncerait la série la
   plus récente).
2. Retirer `vo2Max` de la liste : le premier test tombe aussi (la plus
   ancienne série est justement celle-là).

Restaurer après chaque mutation, **relire le fichier**, et lancer la suite
macOS avant de commiter — `TrendsViewModel` est partagé.

- [x] **Step 6: Commit**

```bash
git add HealthCheckShared CompanionTests
git commit -m "feat: expose the earliest loaded measurement on TrendsViewModel"
```

---

### Task 3: Écran Tendances iOS

**Files:**
- Create: `Companion/Views/CompanionTrendsView.swift`
- Modify: `Companion/CompanionApp.swift`, `Companion/CompanionRootView.swift`,
  `Companion/CompanionAdvisorView.swift` (lien depuis l'Accueil)

**Interfaces:**
- Produces: `CompanionTrendsView(viewModel:)`.

- [x] **Step 1: Écrire la vue**

`Companion/Views/CompanionTrendsView.swift` — quatre cartes, une par série,
sur le gabarit de `TrendChartCard` (macOS) sans le `.help()`, qui n'existe
pas sur iPhone :

```swift
import SwiftUI
import Charts

/// Sous-écran « Tendances » de l'Accueil : quatre courbes sur une période
/// choisie, bornée à ce que l'iPhone possède réellement.
struct CompanionTrendsView: View {
    @ObservedObject var viewModel: TrendsViewModel
    @State private var period: TrendPeriod = .threeMonths

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Picker("Période", selection: $period) {
                    ForEach(TrendPeriod.companionCases, id: \.self) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                historyDepthNote

                card(.restingHeartRate, points: viewModel.restingHeartRate, precision: 0)
                card(.weight, points: viewModel.weight, precision: 1)
                card(.vo2Max, points: viewModel.vo2Max, precision: 1)
                card(.sleep, points: viewModel.sleepHours, precision: 1)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load(period: period) } }
        .onChange(of: period) { _, newPeriod in try? viewModel.load(period: newPeriod) }
        .refreshable { try? viewModel.load(period: period) }
    }

    /// Affichée seulement quand les données commencent après la période
    /// demandée : sinon elle n'apprendrait rien.
    @ViewBuilder
    private var historyDepthNote: some View {
        if let earliest = viewModel.earliestMeasurement,
           earliest > period.startDate(now: Date(), calendar: .current).addingTimeInterval(86_400) {
            Label("Mesures disponibles depuis le \(earliest.formatted(.dateTime.day().month(.wide).year()))",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }

    private func card(_ style: MetricStyle, points: [TrendPoint], precision: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(style.title, systemImage: style.systemImage)
                    .font(.headline)
                    .foregroundStyle(style.tint)
                Spacer()
                if let latest = points.last {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(latest.value.formatted(.number.precision(.fractionLength(0...precision))))
                            .font(.title3.bold())
                            .monospacedDigit()
                        Text(style.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if points.isEmpty {
                Text("Aucune donnée sur cette période.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                chart(style: style, points: points)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func chart(style: MetricStyle, points: [TrendPoint]) -> some View {
        let smoothed = TrendsViewModel.movingAverage(points)
        return Chart {
            ForEach(points, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value(style.title, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(style.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(smoothed, id: \.date) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Moyenne 7 j", point.value),
                         series: .value("Série", "Moyenne 7 j"))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 170)
    }
}
```

L'aire dégradée du Mac est volontairement omise : sur 390 points de large,
une courbe et sa moyenne mobile suffisent, et l'aire ajoutait surtout du
bruit visuel à cette taille.

- [x] **Step 2: Câbler**

`CompanionApp` : `@StateObject private var trendsViewModel: TrendsViewModel`,
construit `TrendsViewModel(store: advisorStore, resolver:
SourcePriorityResolver(priority: ["Watch", "iPhone"]))` — le même résolveur
que les autres view models de cette cible — passé à `CompanionRootView`, qui
le transmet à `CompanionAdvisorView`.

Dans `CompanionAdvisorView`, en bas du contenu, le même gabarit de lien que
« Voir mes séances » au SP3 :

```swift
                NavigationLink {
                    CompanionTrendsView(viewModel: trendsViewModel)
                        .navigationTitle("Tendances")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Voir mes tendances", systemImage: "chart.xyaxis.line")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
```

- [x] **Step 3: Lancer et commiter**

Suite iOS complète (92 attendus, inchangés — cette tâche n'ajoute pas de
test : elle n'ajoute pas de logique, et le dépôt n'a pas de harnais de vue).

```bash
git add Companion
git commit -m "feat(companion): add the Tendances screen"
```

---

### Task 4: Écran Corrélations iOS

**Files:**
- Create: `Companion/Views/CompanionCorrelationsView.swift`
- Modify: `Companion/CompanionApp.swift`, `Companion/CompanionRootView.swift`,
  `Companion/CompanionAdvisorView.swift`
- Modify: `ARCHITECTURE.md`, `ARCHITECTURE_EN.md`

**Interfaces:**
- Produces: `CompanionCorrelationsView(viewModel:)`.

`CorrelationsViewModel` travaille déjà sur 180 jours fixes
(`windowDays = 180`) : il n'a **rien** à changer pour l'iPhone, sa fenêtre
coïncide exactement avec celle de HealthKit local. C'est le seul écran du
chantier dans ce cas.

- [x] **Step 1: Écrire la vue**

`Companion/Views/CompanionCorrelationsView.swift` : l'avertissement sur la
causalité en tête (il compte autant que les cartes — un r fort invite à
conclure), puis une carte par question avec son r, sa lecture en français et
son nuage de points.

```swift
import SwiftUI
import Charts

/// Sous-écran « Corrélations » de l'Accueil. `CorrelationsViewModel` tourne
/// sur 180 jours fixes, exactement la fenêtre lue dans HealthKit : rien à
/// borner ici, contrairement aux Tendances.
struct CompanionCorrelationsView: View {
    @ObservedObject var viewModel: CorrelationsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Sur tes \(CorrelationsViewModel.windowDays) derniers jours. La corrélation mesure un lien statistique, pas une cause : un r fort peut venir d'un facteur commun (saison, routine, maladie).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(viewModel.cards, id: \.question) { card in
                    correlationCard(card)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private func correlationCard(_ card: CorrelationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.question)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let result = card.result {
                    Text("r = \(result.r.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2))))")
                        .font(.callout.bold())
                        .monospacedDigit()
                        .foregroundStyle(strengthColor(result.r))
                }
            }

            Text(card.reading)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result = card.result {
                Chart(result.points, id: \.day) { point in
                    PointMark(x: .value(card.xLabel, point.x), y: .value(card.yLabel, point.y))
                        .foregroundStyle(strengthColor(result.r).opacity(0.55))
                        .symbolSize(24)
                }
                .chartXAxisLabel(card.xLabel)
                .chartYAxisLabel(card.yLabel)
                .chartXScale(domain: .automatic(includesZero: false))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func strengthColor(_ r: Double) -> Color {
        switch abs(r) {
        case 0.6...: return .purple
        case 0.4..<0.6: return .blue
        case 0.2..<0.4: return .teal
        default: return .gray
        }
    }
}
```

- [x] **Step 2: Câbler**

Même chemin que la tâche 3 : `correlationsViewModel` dans `CompanionApp`,
transmis jusqu'à `CompanionAdvisorView`, second `NavigationLink` sous le
premier — « Voir mes corrélations », `chart.dots.scatter`.

- [x] **Step 3: Suites complètes**

iOS (92) et macOS (279). Les deux, parce que la tâche 1 a déplacé un type
partagé et que la suite macOS est le seul endroit où ce déplacement peut
casser.

- [x] **Step 4: Contrôle à l'écran**

Installer sur l'iPhone **déverrouillé**, et vérifier, dans l'ordre :
l'Accueil porte les deux liens ; le sélecteur de Tendances propose quatre
périodes et s'arrête à 6 mois ; les quatre courbes s'affichent ; la mention
« Mesures disponibles depuis le … » apparaît si l'historique est plus court
que la période choisie — et **n'apparaît pas** sinon (une mention systématique
serait un bug aussi sûrement qu'une mention absente) ; Corrélations affiche
ses cartes, celles sans échantillon suffisant montrant leur explication.

Le poids sera vide tant que le SP5 n'a pas livré la lecture de `BodyMass`
depuis HealthKit : c'est attendu, la carte doit dire « Aucune donnée sur
cette période » et non afficher un graphique vide.

- [x] **Step 5: Documentation et commit**

`ARCHITECTURE.md` + `ARCHITECTURE_EN.md` (miroirs, même tour), `CHANGES.md`,
`TODOS.md`, `MEMORY.md`, `PLAN.md`, `COMMANDS.md`.

```bash
git add Companion ARCHITECTURE.md ARCHITECTURE_EN.md docs
git commit -m "feat(companion): add the Correlations screen"
```

---

## Definition of done

- L'Accueil ouvre Tendances et Corrélations en sous-écrans.
- Le sélecteur iOS s'arrête à 6 mois, et l'écran dit depuis quand il a des
  mesures quand l'historique est plus court que la période demandée.
- `MetricStyle` est partagé : une métrique garde la même couleur sur les deux
  cibles.
- 92 tests iOS, 279 macOS. Chaque garde vue échouer contre sa mutation, aucune
  satisfiable à vide, fichier relu avant commit.
- Contrôle à l'écran fait, documentation à jour.
