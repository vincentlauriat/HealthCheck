import Foundation

struct ScoreComponent: Equatable {
    let name: String
    let systemImage: String
    let score: Double // 0...100
    let detail: String
    /// Part réelle de cette composante dans le score, après redistribution du
    /// poids des composantes absentes. `nil` quand la part n'est pas connue —
    /// une composante construite hors de `readiness(...)`, dans un test.
    let share: Double?
    /// Combien d'échantillons ont produit la valeur du jour. Une composante
    /// assise sur une seule mesure vaut autant qu'une assise sur neuf dans le
    /// calcul, alors qu'elle est bien plus volatile : c'est le seul endroit où
    /// cette différence devient visible.
    let sampleCount: Int?

    init(name: String, systemImage: String, score: Double, detail: String,
         share: Double? = nil, sampleCount: Int? = nil) {
        self.name = name
        self.systemImage = systemImage
        self.score = score
        self.detail = detail
        self.share = share
        self.sampleCount = sampleCount
    }

    /// « 1 mesure » / « 3 mesures », ou `nil` quand la profondeur est inconnue.
    /// Vit ici plutôt que dans chaque vue : les deux applications l'affichent.
    var depthLabel: String? {
        sampleCount.map { $0 <= 1 ? "\($0) mesure" : "\($0) mesures" }
    }
}

/// Une composante que le score n'a pas pu évaluer aujourd'hui, faute de mesure
/// du jour ou d'une baseline d'au moins `minimumBaselineCount` jours.
struct MissingComponent: Equatable {
    let name: String
    let systemImage: String
    /// Poids nominal, celui qu'elle aurait pesé si elle avait été mesurée.
    let nominalWeight: Double
    /// Pourquoi elle manque, en clair. Rédigée capitalisée : c'est une
    /// phrase, pas un fragment à recoller à l'affichage.
    let reason: String
}

struct ReadinessScore: Equatable {
    let value: Double // 0...100, moyenne pondérée des composantes disponibles
    let label: String
    let components: [ScoreComponent]
    /// Ce que le score n'a **pas** pu mesurer. Sans cette liste, un score amputé
    /// du sommeil affiche 97/100 sans que rien n'indique que sa composante la
    /// plus lourde (0,35) manque et a été redistribuée sur les autres.
    let missing: [MissingComponent]
    /// Part du panier nominal réellement mesurée, de 0 à 1 : 1,0 quand les
    /// quatre composantes sont là, 0,10 quand seul l'équilibre d'activité
    /// l'est. C'est `totalWeight` avant renormalisation — celui-là même que
    /// la redistribution efface, et dont l'effacement rendait un panier
    /// minuscule indiscernable d'un panier complet.
    let measuredWeight: Double

    /// `false` quand trop peu du panier a été mesuré pour qu'un chiffre
    /// veuille dire quelque chose. Le score reste calculé : ce sont les vues
    /// et les moteurs consommateurs qui décident de ne pas s'en servir, plutôt
    /// qu'une valeur absente qui ferait disparaître la carte sans explication.
    var isConclusive: Bool { measuredWeight >= HealthScoreEngine.minimumMeasuredWeight }

    init(value: Double, label: String, components: [ScoreComponent],
         missing: [MissingComponent] = [], measuredWeight: Double = 1) {
        self.value = value
        self.label = label
        self.components = components
        self.missing = missing
        self.measuredWeight = measuredWeight
    }
}

/// Score de forme quotidien façon « recovery » : chaque composante compare la
/// valeur du jour à la baseline personnelle (fenêtre glissante ~30 jours) et
/// produit un score 0-100. Le score global est la moyenne pondérée des
/// composantes disponibles — une métrique absente réduit le panier, elle ne
/// pénalise pas.
enum HealthScoreEngine {
    static let minimumBaselineCount = 5

    /// Part minimale du panier nominal qui doit avoir été mesurée pour qu'un
    /// score soit annoncé. La moitié : en deçà, la majorité de ce que le score
    /// prétend résumer n'a pas été observée.
    ///
    /// Le 2026-09-04, le Mac annonçait 13,8 « Récupération conseillée » sur le
    /// seul équilibre d'activité — 0,10 de poids nominal redistribué à 100 %,
    /// et cette seule composante assise sur une journée tronquée. Un verdict
    /// tranché sorti de presque rien. Ce seuil est un choix, pas une mesure ;
    /// il est ici plutôt que dans une vue pour que les deux applications et
    /// les moteurs consommateurs s'accordent sur la même définition.
    static let minimumMeasuredWeight = 0.50

    /// FC repos : en dessous de sa normale = bon signe, au-dessus = fatigue.
    /// +5 % au-dessus de la baseline → 70 ; +10 % → 40.
    static func restingHeartRateScore(today: Double, baseline: [Double], sampleCount: Int? = nil) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, today > 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let deviation = (today - mean) / mean
        let score = (100 - deviation * 600).clamped(to: 0...100)
        return ScoreComponent(
            name: "FC repos",
            systemImage: "heart.fill",
            score: score,
            detail: "\(Int(today.rounded())) bpm · normale \(Int(mean.rounded()))",
            sampleCount: sampleCount
        )
    }

    /// HRV (SDNN) : au-dessus de sa normale = bonne récupération.
    /// −10 % sous la baseline → 70.
    static func hrvScore(today: Double, baseline: [Double], sampleCount: Int? = nil) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, today > 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let deviation = (today - mean) / mean
        let score = (100 + deviation * 300).clamped(to: 0...100)
        return ScoreComponent(
            name: "Variabilité cardiaque",
            systemImage: "waveform.path.ecg",
            score: score,
            detail: "\(Int(today.rounded())) ms · normale \(Int(mean.rounded()))",
            sampleCount: sampleCount
        )
    }

    /// Sommeil : la nuit dernière rapportée à la durée habituelle.
    /// Nuit complète (≥ baseline) → 100 ; 80 % de la baseline → 80.
    static func sleepScore(lastNightHours: Double, baseline: [Double], sampleCount: Int? = nil) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, lastNightHours > 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let ratio = lastNightHours / mean
        let score = (ratio * 100).clamped(to: 0...100)
        return ScoreComponent(
            name: "Sommeil",
            systemImage: "moon.zzz.fill",
            score: score,
            detail: String(format: "%.1f h · habituel %.1f h", lastNightHours, mean),
            sampleCount: sampleCount
        )
    }

    /// Équilibre d'activité : la veille comparée à l'habitude — l'inactivité
    /// comme l'excès s'écartent de l'équilibre. ±25 % → 70.
    static func activityBalanceScore(yesterday: Double, baseline: [Double], sampleCount: Int? = nil) -> ScoreComponent? {
        guard baseline.count >= minimumBaselineCount, yesterday >= 0 else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else { return nil }
        let deviation = abs((yesterday - mean) / mean)
        let score = (100 - deviation * 120).clamped(to: 0...100)
        return ScoreComponent(
            name: "Équilibre d'activité",
            systemImage: "flame.fill",
            score: score,
            detail: "\(Int(yesterday.rounded())) kcal hier · habituel \(Int(mean.rounded()))",
            sampleCount: sampleCount
        )
    }

    /// Agrège les composantes disponibles en score global pondéré.
    /// Poids : sommeil 0,35 · FC repos 0,30 · HRV 0,25 · activité 0,10
    /// (renormalisés sur les composantes réellement présentes).
    /// Ce que pèse chaque composante quand elle est mesurée, et comment la
    /// nommer quand elle ne l'est pas. Table unique : deux listes séparées
    /// finiraient par diverger, et c'est le libellé de l'absence qui explique
    /// à l'utilisateur pourquoi son score vaut ce qu'il vaut.
    private static let catalogue: [(name: String, systemImage: String, weight: Double, reason: String)] = [
        ("Sommeil", "moon.zzz.fill", 0.35, "Aucune nuit enregistrée depuis hier"),
        ("FC repos", "heart.fill", 0.30, "Aucune fréquence au repos aujourd'hui"),
        ("Variabilité cardiaque", "waveform.path.ecg", 0.25, "Aucune mesure de VFC aujourd'hui"),
        // Deux absences possibles derrière un même libellé : aucune dépense
        // enregistrée hier, ou une journée d'hier que la synchro a coupée en
        // route. La phrase couvre les deux plutôt que d'en affirmer une.
        ("Équilibre d'activité", "flame.fill", 0.10, "Pas de journée de dépense complète avant aujourd'hui")
    ]

    static func readiness(
        sleep: ScoreComponent?,
        restingHeartRate: ScoreComponent?,
        hrv: ScoreComponent?,
        activity: ScoreComponent?
    ) -> ReadinessScore? {
        let entries = zip(catalogue, [sleep, restingHeartRate, hrv, activity])
        let weighted = entries.compactMap { entry, component in component.map { ($0, entry.weight) } }

        guard !weighted.isEmpty else { return nil }

        let totalWeight = weighted.reduce(0) { $0 + $1.1 }
        let value = weighted.reduce(0) { $0 + $1.0.score * $1.1 } / totalWeight

        let components = weighted.map { component, weight in
            ScoreComponent(name: component.name, systemImage: component.systemImage,
                           score: component.score, detail: component.detail,
                           share: weight / totalWeight, sampleCount: component.sampleCount)
        }
        let missing = entries.compactMap { entry, component in
            component == nil
                ? MissingComponent(name: entry.name, systemImage: entry.systemImage,
                                   nominalWeight: entry.weight, reason: entry.reason)
                : nil
        }
        return ReadinessScore(value: value, label: label(for: value),
                              components: components, missing: missing,
                              measuredWeight: totalWeight)
    }

    /// Explication affichée par les deux applications. Elle vit ici, contre la
    /// table des poids qu'elle cite, pour ne pas dériver d'elle — c'est le seul
    /// endroit où la formule est écrite deux fois, en code et en français.
    static let formulaExplanation = """
        Moyenne pondérée de quatre composantes — sommeil 35 %, FC repos 30 %, \
        variabilité cardiaque 25 %, équilibre d'activité 10 % — chacune comparée \
        à votre normale des 30 derniers jours. Une composante non mesurée est \
        retirée du calcul et son poids réparti sur les autres. La valeur du jour \
        est la moyenne des échantillons connus à cet instant : le score se \
        précise à mesure que la journée avance. En deçà de la moitié du panier \
        réellement mesurée, aucun score n'est annoncé — un chiffre tiré d'une \
        seule composante se lirait comme un verdict.
        """

    static func label(for score: Double) -> String {
        switch score {
        case 85...: return "Excellente forme"
        case 70..<85: return "Bonne forme"
        case 50..<70: return "Forme correcte"
        default: return "Récupération conseillée"
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
