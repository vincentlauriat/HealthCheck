import XCTest
@testable import HealthCheckCompanion

@MainActor
final class CompanionAdvisorViewModelTests: XCTestCase {
    private func record(type: String, sourceName: String, value: Double, start: Date) -> HealthRecord {
        HealthRecord(type: type, sourceName: sourceName, device: nil, unit: nil, value: value, startDate: start, endDate: start.addingTimeInterval(300), creationDate: start)
    }

    // Baseline dégradée : FC repos +10 % vs. 10 jours à 60 bpm -> readiness
    // "Récupération conseillée" -> palier .repos. Fixture identique à celle
    // du sous-projet 3 (weight-advisor), déjà vérifiée produire ce résultat.
    private func insertDegradedRecoveryHistory(_ store: HealthStore, now: Date, calendar: Calendar) throws {
        var records: [HealthRecord] = (1...10).map { daysAgo in
            record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch", value: 60,
                  start: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600))
        }
        records.append(record(type: "HKQuantityTypeIdentifierRestingHeartRate", sourceName: "Watch",
                              value: 66, start: calendar.startOfDay(for: now).addingTimeInterval(3600)))
        // Une seconde composante de récupération. La FC repos seule ne pèse
        // que 0,30 du panier nominal, sous `minimumMeasuredWeight` : le moteur
        // refuserait de conclure et le conseil du jour se tairait avec lui.
        // VFC 10 jours à 40 ms puis 20 aujourd'hui → composante à 0, panier à
        // 0,55, score global ≈ 22 : le palier observé reste REPOS.
        records += (1...10).map { daysAgo in
            record(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", sourceName: "Watch", value: 40,
                  start: calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!.addingTimeInterval(3600))
        }
        records.append(record(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", sourceName: "Watch",
                              value: 20, start: calendar.startOfDay(for: now).addingTimeInterval(3600)))
        try store.insertRecords(records)
    }

    func test_refresh_computesReadinessAndDailyAdviceFromLocalStore() async throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        try insertDegradedRecoveryHistory(store, now: now, calendar: calendar)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        XCTAssertEqual(viewModel.readiness?.label, "Récupération conseillée")
        XCTAssertEqual(viewModel.dailyAdvice?.tier, .repos)
        XCTAssertEqual(viewModel.dailyAdvice?.message,
                      "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_refresh_vo2MaxTrendComputedFromLocalStore() async throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current
        // Fenêtre récente (30j) à 45, fenêtre antérieure (30-120j) à 40 ->
        // delta +5, largement au-dessus de meaningfulDeltaThreshold (1.0) -> .rising.
        var records: [HealthRecord] = []
        for daysAgo in stride(from: 5, through: 25, by: 10) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 45,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        for daysAgo in stride(from: 45, through: 105, by: 20) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        try store.insertRecords(records)

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertEqual(viewModel.vo2Trend?.verdict, .rising)
    }

    /// Base vide : plus rien ne casse, et le score existe désormais sous une
    /// forme non concluante plutôt que `nil` — c'est lui qui porte la liste
    /// des quatre absences, la seule chose que l'écran ait à dire. Aucun
    /// chiffre n'en sort : ni conseil du jour, ni verdict.
    func test_refresh_emptyStore_reportsAnInconclusiveScoreWithoutError() async throws {
        let store = try HealthStore(path: ":memory:")
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.storeUnavailable)
        let readiness = try XCTUnwrap(viewModel.readiness)
        XCTAssertFalse(readiness.isConclusive)
        XCTAssertEqual(readiness.measuredWeight, 0)
        XCTAssertEqual(readiness.missing.count, 4,
                       "les quatre absences sont ce qui reste à afficher")
        XCTAssertNil(viewModel.dailyAdvice)
        XCTAssertNil(viewModel.vo2Trend)
        XCTAssertNil(viewModel.vo2MaxAlert)
    }

    // Spec §6 item 3 : "verdict de tendance + alerte de stagnation le cas
    // échéant" — la carte VO2max doit pouvoir afficher l'alerte .info
    // (stable sous charge soutenue), pas seulement la .warning qui peut
    // remonter par substitution dans DailyAdviceEngine. Fixture de charge
    // identique (chronic = 10 km/semaine >= meaningfulChronicKm 8.0) à celle
    // déjà vérifiée dans DashboardViewModelTests.
    func test_refresh_exposesVO2MaxStagnationAlertEvenWhenInfoSeverity() async throws {
        let store = try HealthStore(path: ":memory:")
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(23 * 3600)
        let calendar = Calendar.current

        // Fenêtre récente (30j) à 40.3, fenêtre antérieure (30-120j) à 40.0 ->
        // delta +0.3, sous meaningfulDeltaThreshold (1.0) -> .stable.
        var records: [HealthRecord] = []
        for daysAgo in stride(from: 5, through: 25, by: 10) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40.3,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        for daysAgo in stride(from: 45, through: 105, by: 20) {
            records.append(record(type: "HKQuantityTypeIdentifierVO2Max", sourceName: "Watch", value: 40.0,
                                  start: calendar.date(byAdding: .day, value: -daysAgo, to: now)!))
        }
        try store.insertRecords(records)

        func run(daysAgo: Int, km: Double) -> Workout {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return Workout(activityType: "HKWorkoutActivityTypeRunning", sourceName: "Watch",
                           duration: 60, durationUnit: "min",
                           totalDistance: km, totalDistanceUnit: "km",
                           totalEnergyBurned: nil, totalEnergyBurnedUnit: nil,
                           startDate: start, endDate: start.addingTimeInterval(3600),
                           routeFileName: nil)
        }
        try store.insertWorkouts([
            run(daysAgo: 25, km: 10.0),
            run(daysAgo: 18, km: 10.0),
            run(daysAgo: 11, km: 10.0),
            run(daysAgo: 4, km: 10.0)
        ])

        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertEqual(viewModel.vo2Trend?.verdict, .stable)
        XCTAssertEqual(viewModel.vo2MaxAlert?.severity, .info)
        XCTAssertEqual(viewModel.vo2MaxAlert?.message,
                      "VO2max stable malgré une charge d'entraînement soutenue — un palier normal, ou un signal pour varier l'intensité.")
    }

    func test_refresh_storeUnavailable_setsFlagWithoutThrowing() async {
        let store = HealthStore(unavailable: ())
        let viewModel = CompanionAdvisorViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]))
        await viewModel.refresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertTrue(viewModel.storeUnavailable)
        XCTAssertNil(viewModel.readiness)
        XCTAssertNil(viewModel.dailyAdvice)
    }

    // MARK: - Cohérence entre écrans

    /// Accueil et Entraînement affichent tous deux `VO2MaxTrend.recentAverage`
    /// sous le même libellé « VO2max ». Ils doivent donc afficher le même
    /// nombre. Rien ne le garantit structurellement : chacun lit le store de
    /// son côté, l'un sur les 120 jours en dur de `WellnessOrchestrator`,
    /// l'autre sur `TrainingViewModel.vo2LookbackDays`. Faire diverger ces
    /// deux fenêtres donnerait deux VO2max différentes dans la même
    /// application, exactement le symptôme rapporté le 2026-09-03.
    func test_homeAndTraining_showTheSameVO2Max() async throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_859_360))
            .addingTimeInterval(23 * 3600)

        // La fenêtre antérieure est en pente : plus l'échantillon est vieux,
        // plus il est bas. C'est ce qui rend la garde falsifiable — avec sept
        // valeurs identiques, tronquer la fenêtre de lecture ne déplacerait
        // aucune moyenne et le test passerait contre le bug qu'il prétend
        // attraper.
        let recent = [0, 7, 14, 21, 28].map { (daysAgo: $0, value: 52.0) }
        let prior = [(35, 54.0), (49, 52.0), (63, 50.0), (77, 48.0),
                     (91, 44.0), (105, 42.0), (119, 40.0)]
            .map { (daysAgo: $0.0, value: $0.1) }
        try store.insertRecords((recent + prior).map { sample in
            let start = calendar.date(byAdding: .day, value: -sample.daysAgo,
                                      to: calendar.startOfDay(for: now))!.addingTimeInterval(7 * 3600)
            return HealthRecord(type: VO2MaxEngine.vo2MaxType, sourceName: "Apple\u{00a0}Watch de Vincent",
                                device: nil, unit: "mL/min·kg", value: sample.value,
                                startDate: start, endDate: start, creationDate: start)
        })

        let home = CompanionAdvisorViewModel(store: store,
                                             resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
                                             now: { now })
        await home.refresh()
        let training = TrainingViewModel(store: store, now: { now })
        try training.load()

        let homeTrend = try XCTUnwrap(home.vo2Trend, "l'Accueil doit produire une tendance VO2max")
        let trainingTrend = try XCTUnwrap(training.vo2MaxStatus?.trend,
                                          "l'Entraînement doit produire une tendance VO2max")
        XCTAssertEqual(homeTrend, trainingTrend,
                       "les deux écrans affichent recentAverage sous le même libellé")
        // Vérifie la fixture elle-même : la moyenne antérieure ne vaut celle
        // des sept échantillons que si la fenêtre de lecture les couvre tous.
        // Sans cette assertion, une fenêtre tronquée resterait invisible.
        XCTAssertEqual(homeTrend.priorAverage, (54.0 + 52 + 50 + 48 + 44 + 42 + 40) / 7,
                       accuracy: 0.001, "les 90 jours antérieurs doivent être lus en entier")
    }

    // MARK: - Poids

    /// Une pesée est un échantillon instantané : `startDate == endDate`, comme
    /// ce que `HKMapper` produit réellement depuis HealthKit.
    private func weighIn(kg: Double, daysAgo: Int, now: Date, calendar: Calendar) -> HealthRecord {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(7 * 3600)
        return HealthRecord(type: "HKQuantityTypeIdentifierBodyMass", sourceName: "Withings",
                            device: nil, unit: "kg", value: kg,
                            startDate: day, endDate: day, creationDate: day)
    }

    /// 82 kg sur la fenêtre antérieure, 80 kg sur les 14 derniers jours :
    /// -1 kg/semaine sur 80 kg, soit 1,25 % — au-dessus du repère de 1 %
    /// de `WeightEngine.safeWarningRatePercent`.
    private func insertFastWeightLoss(_ store: HealthStore, now: Date, calendar: Calendar) throws {
        try store.insertRecords((0...27).map {
            weighIn(kg: $0 < 14 ? 80 : 82, daysAgo: $0, now: now, calendar: calendar)
        })
    }

    /// Remplace `test_refresh_neverSurfacesAWeightAlertEvenIfWeightDataExistsLocally`,
    /// écrite au SP1, qui figeait `weightAlert: nil` en invoquant un non-goal
    /// que la spec ne pose pas : son §2 exclut l'import zip, l'OAuth, la
    /// synchro Withings et le Sankey, pas l'alerte de poids. Sur ce point la
    /// spec dit l'inverse — le view model partagé « se met à produire l'alerte
    /// de lui-même une fois le poids ingéré ». Sa moitié utile — pas d'alerte
    /// sans pesée — est conservée ci-dessous en première moitié.
    ///
    /// Depuis le SP5 l'iPhone ingère le poids localement, donc son Accueil doit
    /// en tenir compte comme celui du Mac. Sans cela les deux applications
    /// donneraient des conseils différents sur les mêmes données — la
    /// divergence exacte que ce sous-projet devait supprimer.
    func test_refresh_letsAFastWeightLossRefineTheDailyAdvice() async throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_859_360))
            .addingTimeInterval(23 * 3600)
        try insertDegradedRecoveryHistory(store, now: now, calendar: calendar)

        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
        let withoutWeight = CompanionAdvisorViewModel(store: store, resolver: resolver, now: { now })
        await withoutWeight.refresh()
        let genericMessage = try XCTUnwrap(withoutWeight.dailyAdvice?.message)
        XCTAssertEqual(genericMessage,
                       "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.",
                       "sans pesée en base, `WeightEngine` rend nil et le conseil reste générique")

        try insertFastWeightLoss(store, now: now, calendar: calendar)
        let withWeight = CompanionAdvisorViewModel(store: store, resolver: resolver, now: { now })
        await withWeight.refresh()

        XCTAssertEqual(withWeight.dailyAdvice?.message,
                       "Rythme de variation du poids au-dessus du repère usuel (≈1 %/semaine).",
                       "le conseil du jour doit être affiné par l'alerte de poids")
        XCTAssertNotEqual(withWeight.dailyAdvice?.message, genericMessage)
    }

    // MARK: - Déport hors du MainActor

    /// Fabrique un instantané d'accueil minimal, identifiable par le score de
    /// forme — les deux gardes ci-dessous ne s'intéressent qu'à « quel
    /// résultat a été appliqué, et quand ».
    private func wellness(readiness value: Double) -> CompanionHomeSnapshot {
        let empty = PeriodSummary(steps: 0, distanceKm: 0, activeEnergyKcal: 0,
                                  exerciseMinutes: 0, restingHeartRate: nil)
        return CompanionHomeSnapshot(
            wellness: WellnessOrchestrator.Result(
                readiness: ReadinessScore(value: value, label: "Forme correcte", components: []),
                vo2Trend: nil,
                loadAssessment: LoadAssessment(acuteKm: 0, chronicWeeklyKm: 0, acwr: nil, alerts: []),
                vo2MaxAlert: nil, hrDaily: [], sleepNights: []),
            today: empty, thisWeek: empty, lastWeek: nil, insights: [], weightAlert: nil)
    }

    /// `hasLoaded` ne doit pas passer à `true` avant la fin du calcul : la vue
    /// en déduirait « Pas encore assez de données » (état chargé + trois
    /// valeurs encore nulles) pendant toute la lecture — soit précisément les
    /// quelques secondes que le déport hors du `MainActor` sert à couvrir.
    func test_refresh_doesNotClaimToBeLoadedWhileTheComputationIsStillRunning() async throws {
        let store = try HealthStore(path: ":memory:")
        let started = expectation(description: "calcul démarré")
        let release = DispatchSemaphore(value: 0)
        let result = wellness(readiness: 70)
        let viewModel = CompanionAdvisorViewModel(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch"]),
            compute: { _, _, _, _ in
                started.fulfill()
                release.wait()
                return result
            })

        let refresh = Task { await viewModel.refresh() }
        await fulfillment(of: [started], timeout: 2)

        XCTAssertFalse(viewModel.hasLoaded, "l'écran ne doit pas se déclarer chargé tant que le calcul court")

        release.signal()
        await refresh.value
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(viewModel.readiness?.value, 70)
    }

    /// Deux `refresh()` concurrents (retour au premier plan pendant un
    /// pull-to-refresh) : le résultat du plus ancien arrive en dernier et ne
    /// doit pas écraser celui du plus récent.
    func test_refresh_staleResultDoesNotOverwriteANewerOne() async throws {
        let store = try HealthStore(path: ":memory:")
        let firstStarted = expectation(description: "premier calcul démarré")
        let releaseFirst = DispatchSemaphore(value: 0)
        let stale = wellness(readiness: 10)
        let fresh = wellness(readiness: 90)
        let callCount = NSLock()
        nonisolated(unsafe) var calls = 0
        let viewModel = CompanionAdvisorViewModel(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch"]),
            compute: { _, _, _, _ in
                callCount.lock()
                calls += 1
                let isFirst = calls == 1
                callCount.unlock()
                guard isFirst else { return fresh }
                firstStarted.fulfill()
                releaseFirst.wait()
                return stale
            })

        let first = Task { await viewModel.refresh() }
        await fulfillment(of: [firstStarted], timeout: 2)
        await viewModel.refresh()          // le second calcul finit en premier
        XCTAssertEqual(viewModel.readiness?.value, 90)

        releaseFirst.signal()
        await first.value

        XCTAssertEqual(viewModel.readiness?.value, 90,
                      "le résultat périmé du premier refresh ne doit pas écraser celui du second")
    }

    /// L'Accueil de l'iPhone doit produire les mêmes agrégats que celui du
    /// Mac, et les produire dans la passe détachée : `refresh()` reste
    /// asynchrone, rien n'est recalculé sur le `MainActor`.
    func test_refresh_alsoPublishesTodaysSummaryAndInsights() async throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = Calendar.current
            .startOfDay(for: Date(timeIntervalSince1970: 1_756_000_000))
            .addingTimeInterval(20 * 3600)
        let morning = calendar.startOfDay(for: now).addingTimeInterval(8 * 3600)
        try store.insertRecords([
            record(type: "HKQuantityTypeIdentifierStepCount", sourceName: "Watch", value: 7200, start: morning),
            record(type: "HKQuantityTypeIdentifierActiveEnergyBurned", sourceName: "Watch", value: 350, start: morning)
        ])

        let viewModel = CompanionAdvisorViewModel(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]), now: { now })
        await viewModel.refresh()

        XCTAssertEqual(viewModel.today?.steps, 7200)
        XCTAssertEqual(viewModel.today?.activeEnergyKcal, 350)
        XCTAssertNotNil(viewModel.thisWeek)
    }
}
