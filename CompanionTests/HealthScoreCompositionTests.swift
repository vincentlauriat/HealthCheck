import XCTest
@testable import HealthCheckCompanion

/// `HealthScoreEngine` vit dans `HealthCheckShared`, donc les deux cibles le
/// compilent. Ces gardes sont écrites côté Companion parce que le schéma de
/// test macOS lance l'application hôte, qui ouvre la vraie base de production
/// — les y mettre rendrait leur exécution risquée.
final class HealthScoreCompositionTests: XCTestCase {
    private func component(_ name: String, score: Double) -> ScoreComponent {
        ScoreComponent(name: name, systemImage: "circle", score: score, detail: "—")
    }

    /// Le score ne pénalise pas une composante absente : il redistribue son
    /// poids sur les autres. C'est défendable, mais invisible — le 2026-09-03,
    /// faute de nuit enregistrée depuis le 25 août, le Mac affichait 97/100
    /// « Excellente forme » alors que sa composante la plus lourde (0,35)
    /// manquait. Le score doit donc dire ce qu'il n'a pas mesuré.
    /// Rien de mesuré ne doit pas rendre `nil` : les deux vues masquaient
    /// alors toute la section « Forme du jour », et la carte disparaissait
    /// sans explication. C'est le cas réel du Mac le 2026-09-04, une fois les
    /// deux verrous en place.
    func test_readiness_withNothingMeasured_stillReportsTheFourAbsences() throws {
        let score = try XCTUnwrap(HealthScoreEngine.readiness(
            sleep: nil, restingHeartRate: nil, hrv: nil, activity: nil),
            "un écran vide n'apprend rien : il faut pouvoir dire ce qui manque")

        XCTAssertEqual(score.measuredWeight, 0)
        XCTAssertFalse(score.isConclusive)
        XCTAssertTrue(score.components.isEmpty)
        XCTAssertEqual(score.missing.count, 4)
    }

    /// Le seuil de refus (b). Le 2026-09-04 le Mac annonçait 13,8
    /// « Récupération conseillée » sur le seul équilibre d'activité : 0,10 de
    /// poids nominal redistribué à 100 %, un verdict tranché sorti de presque
    /// rien.
    func test_readiness_withOnlyTheLightestComponent_refusesToConclude() throws {
        let score = try XCTUnwrap(HealthScoreEngine.readiness(
            sleep: nil, restingHeartRate: nil, hrv: nil,
            activity: component("Équilibre d'activité", score: 13.8)))

        XCTAssertEqual(score.measuredWeight, 0.10, accuracy: 0.0001,
                       "seul l'équilibre d'activité a été mesuré")
        XCTAssertFalse(score.isConclusive,
                       "0,10 du panier ne suffit pas à prononcer un verdict")
        XCTAssertEqual(score.missing.count, 3)
    }

    /// Le seuil ne doit pas non plus refuser un panier raisonnable : sommeil
    /// et FC repos font 0,65, au-dessus de la moitié.
    func test_readiness_withMostOfTheBasket_concludes() throws {
        let score = try XCTUnwrap(HealthScoreEngine.readiness(
            sleep: component("Sommeil", score: 80),
            restingHeartRate: component("FC repos", score: 70),
            hrv: nil, activity: nil))

        XCTAssertEqual(score.measuredWeight, 0.65, accuracy: 0.0001)
        XCTAssertTrue(score.isConclusive)
    }

    /// Un score non concluant ne doit pas ressortir déguisé en conseil du
    /// jour : le conseil se lit comme un verdict.
    func test_dailyAdvice_staysSilentOnAnInconclusiveScore() {
        let inconclusive = try? XCTUnwrap(HealthScoreEngine.readiness(
            sleep: nil, restingHeartRate: nil, hrv: nil,
            activity: component("Équilibre d'activité", score: 13.8)))

        XCTAssertNil(DailyAdviceEngine.advise(readiness: inconclusive, loadAlerts: [],
                                              vo2MaxAlert: nil, weightAlert: nil))
    }

    func test_readiness_reportsWhatItCouldNotMeasure() throws {
        let score = try XCTUnwrap(HealthScoreEngine.readiness(
            sleep: nil,
            restingHeartRate: component("FC repos", score: 100),
            hrv: component("Variabilité cardiaque", score: 100),
            activity: component("Équilibre d'activité", score: 40)))

        let missing = try XCTUnwrap(score.missing.first)
        XCTAssertEqual(score.missing.count, 1)
        XCTAssertEqual(missing.name, "Sommeil")
        XCTAssertEqual(missing.nominalWeight, 0.35, accuracy: 0.0001,
                       "le poids annoncé doit être celui que la composante aurait pesé")
        XCTAssertFalse(missing.reason.isEmpty, "l'absence doit être expliquée en clair")
    }

    /// La part affichée doit être la part **réelle** après redistribution, pas
    /// le poids nominal : sans sommeil, la FC repos ne pèse plus 0,30 mais
    /// 0,30 / 0,65 ≈ 46 %. Afficher 0,30 laisserait croire que le total est
    /// amputé alors qu'il est renormalisé.
    func test_readiness_sharesAreRenormalisedAndSumToOne() throws {
        let score = try XCTUnwrap(HealthScoreEngine.readiness(
            sleep: nil,
            restingHeartRate: component("FC repos", score: 100),
            hrv: component("Variabilité cardiaque", score: 100),
            activity: component("Équilibre d'activité", score: 40)))

        let shares = score.components.map { $0.share ?? 0 }
        XCTAssertEqual(shares.reduce(0, +), 1.0, accuracy: 0.0001)
        XCTAssertEqual(shares[0], 0.30 / 0.65, accuracy: 0.0001, "FC repos")
        XCTAssertEqual(shares[1], 0.25 / 0.65, accuracy: 0.0001, "variabilité cardiaque")
        XCTAssertEqual(shares[2], 0.10 / 0.65, accuracy: 0.0001, "équilibre d'activité")

        // La part n'est pas décorative : elle doit reconstituer le score.
        let recomputed = zip(score.components, shares).reduce(0) { $0 + $1.0.score * $1.1 }
        XCTAssertEqual(recomputed, score.value, accuracy: 0.0001)
    }

    // MARK: - Profondeur de mesure

    private func energyRecord(kcal: Double, daysAgo: Int, hour: Int, now: Date, calendar: Calendar) -> HealthRecord {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(Double(hour) * 3600)
        return HealthRecord(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                            sourceName: "Apple\u{00a0}Watch de Vincent", device: nil, unit: "kcal",
                            value: kcal, startDate: start, endDate: start.addingTimeInterval(300),
                            creationDate: start)
    }

    /// Une journée complète au calendrier ne l'est pas forcément dans les
    /// données (a). Le 2026-09-04, la base du Mac s'arrêtait au 3 septembre à
    /// 10 h 28 : ses 231 kcal de matinée, comparés aux 820 habituels,
    /// produisaient à eux seuls « Récupération conseillée » à 13,8.
    ///
    /// Le critère ne fixe aucune heure limite : hier n'est close que si l'on
    /// connaît quelque chose de postérieur à elle.
    func test_wellness_withYesterdayCutShort_doesNotScoreActivity() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_859_360))
            .addingTimeInterval(20 * 3600)

        // Huit jours pleins de baseline, à 800 kcal réparties sur la journée.
        var records: [HealthRecord] = []
        for day in 2...9 {
            records += [8, 12, 16, 20].map {
                energyRecord(kcal: 200, daysAgo: day, hour: $0, now: now, calendar: calendar)
            }
        }
        // Hier : la synchro s'arrête à 10 h. 200 kcal au lieu de 800.
        records.append(energyRecord(kcal: 200, daysAgo: 1, hour: 10, now: now, calendar: calendar))
        // Une FC repos pour que le score existe : sans elle, écarter
        // l'activité ne laisserait aucune composante et `readiness` serait
        // nil, ce qui ne prouverait rien sur la complétude de la journée.
        records += (1...10).map { hrRecord(bpm: 60, daysAgo: $0, hour: 8, now: now, calendar: calendar) }
        records.append(hrRecord(bpm: 61, daysAgo: 0, hour: 8, now: now, calendar: calendar))
        try store.insertRecords(records)

        let result = try WellnessOrchestrator.compute(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar, today: now)

        let readiness = try XCTUnwrap(result.readiness)
        XCTAssertNil(readiness.components.first { $0.name == "Équilibre d'activité" },
                     "hier est le dernier jour connu : rien ne dit qu'il est entier")
        XCTAssertTrue(readiness.missing.contains { $0.name == "Équilibre d'activité" })
    }

    /// Contre-épreuve : dès qu'un échantillon d'aujourd'hui existe, hier est
    /// close et sa journée est notée normalement. Sans elle, la garde
    /// ci-dessus passerait aussi sur un code qui refuserait toujours.
    func test_wellness_withDataAfterYesterday_scoresActivity() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_859_360))
            .addingTimeInterval(20 * 3600)

        var records: [HealthRecord] = []
        for day in 2...9 {
            records += [8, 12, 16, 20].map {
                energyRecord(kcal: 200, daysAgo: day, hour: $0, now: now, calendar: calendar)
            }
        }
        records.append(energyRecord(kcal: 200, daysAgo: 1, hour: 10, now: now, calendar: calendar))
        records += (1...10).map { hrRecord(bpm: 60, daysAgo: $0, hour: 8, now: now, calendar: calendar) }
        records.append(hrRecord(bpm: 61, daysAgo: 0, hour: 8, now: now, calendar: calendar))
        // Le seul écart avec le test précédent : un échantillon d'aujourd'hui.
        records.append(energyRecord(kcal: 50, daysAgo: 0, hour: 9, now: now, calendar: calendar))
        try store.insertRecords(records)

        let result = try WellnessOrchestrator.compute(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar, today: now)

        let readiness = try XCTUnwrap(result.readiness)
        XCTAssertNotNil(readiness.components.first { $0.name == "Équilibre d'activité" },
                        "hier est close : sa journée se note")
    }

    private func hrRecord(bpm: Double, daysAgo: Int, hour: Int, now: Date, calendar: Calendar) -> HealthRecord {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(Double(hour) * 3600)
        return HealthRecord(type: "HKQuantityTypeIdentifierRestingHeartRate",
                            sourceName: "Apple\u{00a0}Watch de Vincent", device: nil, unit: "count/min",
                            value: bpm, startDate: start, endDate: start.addingTimeInterval(300),
                            creationDate: start)
    }

    /// La valeur « du jour » est la moyenne des échantillons **connus à cet
    /// instant**. Le 2026-09-02, la même journée valait 57,0 vue à une mesure
    /// de VFC et 95,4 vue à neuf — c'est la cause de l'écart de forme entre le
    /// Mac (qui ne voit que ce qui a été poussé) et l'iPhone (qui lit
    /// HealthKit en direct). Le score doit donc dire sur combien de mesures il
    /// repose, sans quoi rien ne distingue les deux situations à l'écran.
    func test_wellness_reportsHowManySamplesTodaysValueRestsOn() throws {
        let store = try HealthStore(path: ":memory:")
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_859_360))
            .addingTimeInterval(20 * 3600)

        var records = (1...10).map { hrRecord(bpm: 60, daysAgo: $0, hour: 8, now: now, calendar: calendar) }
        // Aujourd'hui : trois mesures, à trois heures distinctes.
        records += [8, 12, 16].map { hrRecord(bpm: 62, daysAgo: 0, hour: $0, now: now, calendar: calendar) }
        try store.insertRecords(records)

        let result = try WellnessOrchestrator.compute(
            store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"]),
            calendar: calendar, today: now)

        let hr = try XCTUnwrap(result.readiness?.components.first { $0.name == "FC repos" })
        XCTAssertEqual(hr.sampleCount, 3,
                       "la composante doit porter le nombre de mesures du jour, pas une constante")
    }

    /// Sur un **total**, le nombre d'échantillons ne dit rien de la fiabilité
    /// de la valeur : 506 échantillons d'énergie un jour et 94 le lendemain
    /// sont deux totaux également complets. L'afficher inviterait à y lire une
    /// précision qui n'existe pas — c'est le seul agrégat où la profondeur ne
    /// doit pas remonter.
    func test_dailyTotals_carryNoMeasurementDepth() {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_786_859_360))
        let records = (0..<4).map { index in
            HealthRecord(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                         sourceName: "Apple\u{00a0}Watch de Vincent", device: nil, unit: "kcal",
                         value: 100, startDate: day.addingTimeInterval(Double(index) * 3600),
                         endDate: day.addingTimeInterval(Double(index) * 3600 + 60),
                         creationDate: day)
        }

        let totals = DailyAggregator.totals(records, calendar: calendar)
        XCTAssertEqual(totals.first?.value, 400)
        XCTAssertNil(totals.first?.sampleCount,
                     "un total est complet ou ne l'est pas — sa profondeur n'informe sur rien")

        // Contre-épreuve : sur une moyenne, la profondeur doit bien remonter.
        XCTAssertEqual(DailyAggregator.averages(records, calendar: calendar).first?.sampleCount, 4)
    }

    /// Toutes les composantes présentes : rien ne manque, et les parts valent
    /// les poids nominaux. Garde le cas nominal honnête — sans lui, un moteur
    /// qui déclarerait toujours « Sommeil manquant » passerait la garde
    /// ci-dessus.
    func test_readiness_withEveryComponent_reportsNothingMissing() throws {
        let score = try XCTUnwrap(HealthScoreEngine.readiness(
            sleep: component("Sommeil", score: 80),
            restingHeartRate: component("FC repos", score: 80),
            hrv: component("Variabilité cardiaque", score: 80),
            activity: component("Équilibre d'activité", score: 80)))

        XCTAssertTrue(score.missing.isEmpty)
        XCTAssertEqual(score.components.first?.share ?? 0, 0.35, accuracy: 0.0001)
    }
}
