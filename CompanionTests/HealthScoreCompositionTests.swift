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
