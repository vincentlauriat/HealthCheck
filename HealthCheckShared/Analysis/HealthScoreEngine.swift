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
    /// Ce qui la ferait revenir, adressé à l'utilisateur. Une absence sans
    /// suite à donner se lit comme une panne ; c'est ce qui rendait la carte
    /// « Score indisponible » désagréable alors qu'elle ne signalait rien
    /// d'autre qu'une donnée pas encore là.
    ///
    /// Chaque phrase est écrite pour rester vraie **sans supposer la cause**
    /// de l'absence : le sommeil peut manquer parce que la montre n'a pas été
    /// portée, parce que la synchro est en retard, ou parce que le suivi est
    /// coupé. Dire « portez votre montre la nuit » affirmerait l'une des
    /// trois. Les phrases disent donc ce qui débloque la part, pas ce qui
    /// aurait dû être fait.
    let action: String

    init(name: String, systemImage: String, nominalWeight: Double,
         reason: String, action: String = "") {
        self.name = name
        self.systemImage = systemImage
        self.nominalWeight = nominalWeight
        self.reason = reason
        self.action = action
    }
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

    /// Un signal d'activité rapporté à sa propre normale : de combien la
    /// veille s'écarte-t-elle, en proportion. Interne à
    /// `activityBalanceScore`, qui en compare deux.
    private struct ActivityDeviation {
        let relative: Double
        let yesterday: Double
        let mean: Double
    }

    /// Équilibre d'activité : la veille comparée à l'habitude — l'inactivité
    /// comme l'excès s'écartent de l'équilibre. ±25 % → 70.
    ///
    /// **Deux signaux, pas un.** L'énergie active ne voit pas une grosse
    /// journée de marche. Relevé sur les 30 jours au 2026-09-04 : le rapport
    /// kcal / 1 000 pas va de 32 à 92 selon les jours, un facteur trois. Le
    /// 15 août, 23 387 pas contre 18 300 habituels étaient notés **13,3** sur
    /// la seule énergie, quand les pas plaçaient la journée à 64,9. Une
    /// journée de marche sans séance n'était donc pas comptée.
    ///
    /// La veille est notée sur celui des deux signaux qui la place **le plus
    /// près de son habitude**. Ni l'un ni l'autre ne voit tout : une marche
    /// lente est presque invisible à l'énergie, une sortie vélo l'est aux pas.
    /// Retenir systématiquement le plus sévère punirait le capteur, pas la
    /// personne. Sur ces mêmes 30 jours, la règle déplace la note de plus de
    /// trois points 11 jours sur 31.
    ///
    /// Chaque signal est facultatif et jugé séparément : la composante existe
    /// dès que l'un des deux est disponible avec une baseline suffisante.
    ///
    /// Pas de `sampleCount`, contrairement aux trois autres composantes :
    /// `DailyAggregator.totals` n'en produit pas, et à raison — sur un
    /// **total**, le nombre d'échantillons ne dit rien de la fiabilité de la
    /// valeur. Le paramètre existait et valait toujours `nil`.
    static func activityBalanceScore(
        yesterdayEnergy: Double?, energyBaseline: [Double],
        yesterdaySteps: Double?, stepsBaseline: [Double]
    ) -> ScoreComponent? {
        func deviation(_ yesterday: Double?, _ baseline: [Double]) -> ActivityDeviation? {
            guard let yesterday, yesterday >= 0, baseline.count >= minimumBaselineCount else { return nil }
            let mean = baseline.reduce(0, +) / Double(baseline.count)
            guard mean > 0 else { return nil }
            return ActivityDeviation(relative: (yesterday - mean) / mean, yesterday: yesterday, mean: mean)
        }

        let energy = deviation(yesterdayEnergy, energyBaseline)
        let steps = deviation(yesterdaySteps, stepsBaseline)

        let closest: ActivityDeviation
        switch (energy, steps) {
        case let (.some(e), .some(s)): closest = abs(e.relative) <= abs(s.relative) ? e : s
        case let (.some(e), .none): closest = e
        case let (.none, .some(s)): closest = s
        case (.none, .none): return nil
        }

        let score = (100 - abs(closest.relative) * 120).clamped(to: 0...100)

        // `formatted()` plutôt que l'interpolation brute des autres
        // composantes : un nombre de pas passe les cinq chiffres, et
        // « 32440 pas » ne se lit pas.
        var yesterdayParts: [String] = []
        var habitualParts: [String] = []
        if let energy {
            yesterdayParts.append("\(Int(energy.yesterday.rounded()).formatted()) kcal")
            habitualParts.append(Int(energy.mean.rounded()).formatted())
        }
        if let steps {
            yesterdayParts.append("\(Int(steps.yesterday.rounded()).formatted()) pas")
            habitualParts.append(Int(steps.mean.rounded()).formatted())
        }

        return ScoreComponent(
            name: "Équilibre d'activité",
            systemImage: "flame.fill",
            score: score,
            detail: "\(yesterdayParts.joined(separator: " · ")) hier — habituel \(habitualParts.joined(separator: " · "))"
        )
    }

    /// Agrège les composantes disponibles en score global pondéré.
    /// Poids : sommeil 0,35 · FC repos 0,30 · HRV 0,25 · activité 0,10
    /// (renormalisés sur les composantes réellement présentes).
    /// Ce que pèse chaque composante quand elle est mesurée, et comment la
    /// nommer quand elle ne l'est pas. Table unique : deux listes séparées
    /// finiraient par diverger, et c'est le libellé de l'absence qui explique
    /// à l'utilisateur pourquoi son score vaut ce qu'il vaut.
    private static let catalogue: [(name: String, systemImage: String, weight: Double,
                                    reason: String, action: String)] = [
        ("Sommeil", "moon.zzz.fill", 0.35, "Aucune nuit enregistrée depuis hier",
         "C'est la plus grosse part du score : elle s'ajoute dès qu'une nuit est enregistrée."),
        ("FC repos", "heart.fill", 0.30, "Aucune fréquence au repos aujourd'hui",
         "Une mesure au repos, souvent prise pendant le sommeil, débloque cette part."),
        ("Variabilité cardiaque", "waveform.path.ecg", 0.25, "Aucune mesure de VFC aujourd'hui",
         "Une mesure au calme, souvent prise pendant le sommeil, débloque cette part."),
        // Deux absences possibles derrière un même libellé : aucune activité
        // enregistrée hier, ou une journée d'hier que la synchro a coupée en
        // route. La phrase couvre les deux plutôt que d'en affirmer une.
        ("Équilibre d'activité", "flame.fill", 0.10, "Pas de journée d'activité complète avant aujourd'hui",
         "Bougez : la marche compte autant qu'une séance, vos pas suffisent.")
    ]

    static func readiness(
        sleep: ScoreComponent?,
        restingHeartRate: ScoreComponent?,
        hrv: ScoreComponent?,
        activity: ScoreComponent?
    ) -> ReadinessScore? {
        let entries = zip(catalogue, [sleep, restingHeartRate, hrv, activity])
        let weighted = entries.compactMap { entry, component in component.map { ($0, entry.weight) } }

        // Aucune composante mesurée ne rend plus `nil` : les deux vues
        // masquaient alors toute la section « Forme du jour », et la carte
        // disparaissait sans un mot — un écran vide n'apprend rien, là où la
        // liste des quatre absences dit exactement quoi réparer. Le score
        // vaut 0 et `measuredWeight` aussi, donc `isConclusive` est faux et
        // aucun chiffre n'est affiché.
        let totalWeight = weighted.reduce(0) { $0 + $1.1 }
        let value = totalWeight > 0
            ? weighted.reduce(0) { $0 + $1.0.score * $1.1 } / totalWeight
            : 0

        let components = weighted.map { component, weight in
            ScoreComponent(name: component.name, systemImage: component.systemImage,
                           score: component.score, detail: component.detail,
                           share: weight / totalWeight, sampleCount: component.sampleCount)
        }
        let missing = entries.compactMap { entry, component in
            component == nil
                ? MissingComponent(name: entry.name, systemImage: entry.systemImage,
                                   nominalWeight: entry.weight, reason: entry.reason,
                                   action: entry.action)
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
        à votre normale des 30 derniers jours. L'équilibre d'activité regarde \
        l'énergie active **et** le nombre de pas, et retient celui des deux qui \
        place votre veille le plus près de son habitude : une grosse journée de \
        marche compte même sans séance. Une composante non mesurée est \
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
