import XCTest
@testable import HealthCheck

final class DailyAdviceEngineTests: XCTestCase {
    private func readiness(label: String) -> ReadinessScore {
        ReadinessScore(value: 0, label: label, components: [])
    }

    private func alert(_ severity: LoadAlert.Severity, _ message: String) -> LoadAlert {
        LoadAlert(severity: severity, message: message)
    }

    func test_advise_reposTierAndGenericMessageWhenNoWarningPresent() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Récupération conseillée"),
            loadAlerts: [],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .repos)
        XCTAssertEqual(advice?.message, "Repos ou séance très légère aujourd'hui — laissez la récupération primer sur la performance.")
    }

    func test_advise_prudenceTierAndGenericMessageWhenOnlyInfoAlertsPresent() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "Vous pouvez en faire un peu plus.")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .prudence)
        XCTAssertEqual(advice?.message, "Restez sur des séances modérées aujourd'hui — ce n'est pas le jour pour repousser vos limites.")
    }

    func test_advise_opportuniteTierWhenLabelIsBonneForme() {
        let advice = DailyAdviceEngine.advise(readiness: readiness(label: "Bonne forme"),
                                              loadAlerts: [], vo2MaxAlert: nil, weightAlert: nil)
        XCTAssertEqual(advice?.tier, .opportunite)
        XCTAssertEqual(advice?.message, "Vous êtes en forme — bon moment pour une séance clé.")
    }

    func test_advise_opportuniteTierWhenLabelIsExcellenteForme() {
        let advice = DailyAdviceEngine.advise(readiness: readiness(label: "Excellente forme"),
                                              loadAlerts: [], vo2MaxAlert: nil, weightAlert: nil)
        XCTAssertEqual(advice?.tier, .opportunite)
    }

    func test_advise_warningIgnoredUnderOpportuniteTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Excellente forme"),
            loadAlerts: [alert(.warning, "Vous progressez trop vite — réduisez cette semaine.")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .opportunite)
        XCTAssertEqual(advice?.message, "Vous êtes en forme — bon moment pour une séance clé.",
                      "une alerte .warning ne doit jamais remonter sous le palier opportunité")
    }

    func test_advise_warningSubstitutedUnderReposTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Récupération conseillée"),
            loadAlerts: [alert(.warning, "Vous progressez trop vite — réduisez cette semaine.")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.message, "Vous progressez trop vite — réduisez cette semaine.")
    }

    func test_advise_determinismLoadAlertsWinOverVo2MaxAlertWhenBothWarn() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.warning, "alerte de charge")],
            vo2MaxAlert: alert(.warning, "alerte VO2max"),
            weightAlert: nil
        )
        XCTAssertEqual(advice?.message, "alerte de charge")
    }

    func test_advise_vo2MaxAlertUsedWhenLoadAlertsHaveNoWarning() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "alerte de charge info")],
            vo2MaxAlert: alert(.warning, "alerte VO2max"),
            weightAlert: nil
        )
        XCTAssertEqual(advice?.message, "alerte VO2max")
    }

    func test_advise_nilReadinessReturnsNil() {
        XCTAssertNil(DailyAdviceEngine.advise(readiness: nil, loadAlerts: [], vo2MaxAlert: nil, weightAlert: nil))
    }

    // Un libellé inconnu (renommage futur de HealthScoreEngine.label(for:),
    // par exemple) ne doit jamais retomber silencieusement sur le palier le
    // plus optimiste — ça masquerait une vraie alerte .warning.
    func test_advise_unknownLabelFailsSafeToPrudenceTier() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Libellé inconnu"),
            loadAlerts: [alert(.warning, "alerte de charge")],
            vo2MaxAlert: nil,
            weightAlert: nil
        )
        XCTAssertEqual(advice?.tier, .prudence)
        XCTAssertEqual(advice?.message, "alerte de charge",
                      "palier .prudence : la substitution d'alerte doit rester active")
    }

    func test_advise_weightAlertUsedWhenLoadAndVo2MaxHaveNoWarning() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [alert(.info, "alerte de charge info")],
            vo2MaxAlert: nil,
            weightAlert: alert(.warning, "alerte de poids")
        )
        XCTAssertEqual(advice?.message, "alerte de poids")
    }

    func test_advise_determinismVo2MaxAlertWinsOverWeightAlertWhenBothWarn() {
        let advice = DailyAdviceEngine.advise(
            readiness: readiness(label: "Forme correcte"),
            loadAlerts: [],
            vo2MaxAlert: alert(.warning, "alerte VO2max"),
            weightAlert: alert(.warning, "alerte de poids")
        )
        XCTAssertEqual(advice?.message, "alerte VO2max")
    }
}
