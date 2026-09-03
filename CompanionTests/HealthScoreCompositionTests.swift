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
