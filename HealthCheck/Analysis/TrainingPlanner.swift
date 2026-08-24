import Foundation

/// Rôle d'une semaine dans la préparation.
enum WeekRole: Equatable {
    case currentWeekClosing  // semaine en cours trop entamée pour recevoir des cibles
    case build
    case peak                // course − 2
    case taper               // course − 1
    case raceWeek
}

enum SessionKind: Equatable {
    case longRun
    case hills
    case baseEndurance
    case optionalEasy
    case legOpener
}

struct PlannedSession: Equatable {
    let kind: SessionKind
    let targetKm: Double            // 0 pour les séances définies en durée
    let targetMinutes: Double?      // renseigné pour optionalEasy / legOpener
    let targetClimbM: Double        // consigne seulement — jamais vérifiée (spec §6.1)
    let hrRange: ClosedRange<Double>
    let note: String                 // l'instruction : comment faire la séance
    let rationale: String            // le motif : ce qu'elle entraîne et pourquoi elle existe

    var isOptional: Bool { kind == .optionalEasy }
}

struct PlannedWeek: Equatable {
    let monday: Date
    let role: WeekRole
    let targetKm: Double
    var sessions: [PlannedSession]
}

struct TrainingPlan: Equatable {
    let goal: RaceGoal
    let weeks: [PlannedWeek]
    let hrMax: Double
    /// Vrai quand l'objectif a été créé à moins de deux semaines de sa
    /// course : plus le temps de progresser, on entretient (spec §5.2).
    /// La vue s'en sert pour afficher la mise en garde de §9.
    let isMaintenance: Bool
    /// Base mesurée dont tout l'arc part : `max(charge mesurée avant la
    /// première semaine de construction, minimumStartVolumeKm)`. Exposée
    /// pour que la vue explique le plan sans recalculer l'ancrage.
    let anchorBaseKm: Double
    /// 1.15 (reprise) ou 1.10 (base établie) — le facteur choisi une seule
    /// fois à l'ancrage, exposé pour la même raison que `anchorBaseKm`.
    let rampFactor: Double

    /// Plus longue sortie longue du plan, toutes semaines confondues.
    /// Calculée, pas stockée : elle ne peut pas se désynchroniser des
    /// séances réellement produites.
    var longestPlannedRunKm: Double {
        weeks.flatMap(\.sessions)
            .filter { $0.kind == .longRun }
            .map(\.targetKm)
            .max() ?? 0
    }
}

/// Construit un plan déterministe : mêmes entrées, même plan. Rien n'est
/// persisté — le plan est recalculé à chaque affichage, donc il ne peut
/// pas se désynchroniser de ce qui a réellement été couru.
enum TrainingPlanner {
    static let comebackRampFactor = 1.15
    static let steadyRampFactor = 1.10
    static let minimumStartVolumeKm = 10.0
    static let peakVolumeMultiplier = 1.5
    static let taperFactor = 0.75
    static let raceWeekFactor = 0.5
    static let fallbackPaceMinutesPerKm = 7.0
    static let minimumDaysForTargets = 3
    static let runningActivityType = "HKWorkoutActivityTypeRunning"

    // MARK: - Lectures de charge

    /// Distance d'une séance : la valeur réelle si elle existe, sinon une
    /// estimation à 7:00/km. Le même repli partout — deux définitions
    /// laisseraient le planificateur et le moniteur lire des charges
    /// différentes pour le même historique.
    static func distanceKm(_ workout: Workout) -> Double {
        if let d = workout.totalDistance { return d }
        return WorkoutStatsEngine.durationMinutes(workout) / fallbackPaceMinutesPerKm
    }

    static func acuteKm(history: [Workout], today: Date, calendar: Calendar) -> Double {
        sumKm(history, days: 7, endingOn: today, calendar: calendar)
    }

    static func chronicWeeklyKm(history: [Workout], today: Date, calendar: Calendar) -> Double {
        sumKm(history, days: 28, endingOn: today, calendar: calendar) / 4.0
    }

    private static func sumKm(_ history: [Workout], days: Int, endingOn today: Date,
                              calendar: Calendar) -> Double {
        let endExclusive = calendar.date(byAdding: .day, value: 1,
                                         to: calendar.startOfDay(for: today))!
        let start = calendar.date(byAdding: .day, value: -days, to: endExclusive)!
        return history
            .filter { $0.activityType == runningActivityType }
            .filter { $0.startDate >= start && $0.startDate < endExclusive }
            .reduce(0) { $0 + distanceKm($1) }
    }

    // MARK: - Dates

    static func monday(of date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)  // dimanche = 1
        // .weekday numbering (Sun=1…Sat=7) is independent of firstWeekday.
        let offset = (weekday + 5) % 7                       // lundi → 0, dimanche → 6
        return calendar.date(byAdding: .day, value: -offset, to: start)!
    }

    /// Jours restants dans la semaine, aujourd'hui compris : lundi → 7,
    /// dimanche → 1.
    static func daysRemainingInWeek(from today: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: calendar.startOfDay(for: today))
        // .weekday numbering (Sun=1…Sat=7) is independent of firstWeekday.
        return 7 - ((weekday + 5) % 7)
    }

    // MARK: - Ancrage

    /// Lundi de la première semaine de construction. **Lu sur
    /// `goal.createdAt`, jamais sur `today`** (spec §5.2bis) : la règle de
    /// semaine de départ de §5.2 s'applique une seule fois, à la création.
    /// Sinon la séquence de semaines rétrécit à mesure que la course
    /// approche, tout plan finit dans la branche d'entretien à deux
    /// semaines, et l'affûtage disparaît.
    ///
    /// Conséquence assumée : supprimer puis recréer un objectif redémarre
    /// tout l'arc depuis la charge du moment. Recréer un objectif est un
    /// acte explicite de l'utilisateur, pas un effet de bord.
    static func firstBuildMonday(goal: RaceGoal, calendar: Calendar) -> Date {
        let creationMonday = monday(of: goal.createdAt, calendar: calendar)
        let takesTargets = daysRemainingInWeek(from: goal.createdAt, calendar: calendar)
            >= minimumDaysForTargets
        let candidate = takesTargets
            ? creationMonday
            : calendar.date(byAdding: .day, value: 7, to: creationMonday)!
        // Objectif créé le samedi ou le dimanche qui précède sa propre
        // course : décaler d'une semaine sauterait la course. On garde
        // alors la semaine de création, pour que la semaine de course et
        // son déverrouillage existent quand même.
        let raceMonday = monday(of: goal.raceDate, calendar: calendar)
        return candidate > raceMonday ? creationMonday : candidate
    }

    /// Charge hebdomadaire mesurée **strictement avant** `weekMonday`. On
    /// réutilise `chronicWeeklyKm`/`acuteKm` avec une date décalée d'un
    /// jour — la borne exclusive de `sumKm` tombe alors exactement sur ce
    /// lundi — pour qu'il n'existe qu'une seule définition de la charge.
    static func measuredBaseKm(history: [Workout], before weekMonday: Date,
                               calendar: Calendar) -> Double {
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: weekMonday)!
        return max(chronicWeeklyKm(history: history, today: dayBefore, calendar: calendar),
                   acuteKm(history: history, today: dayBefore, calendar: calendar))
    }

    // MARK: - Plan

    static func plan(goal: RaceGoal, history: [Workout], hrMax: Double,
                     today: Date, calendar: Calendar) -> TrainingPlan {
        let runs = history.filter { $0.activityType == runningActivityType }
        let currentMonday = monday(of: today, calendar: calendar)
        let raceMonday = monday(of: goal.raceDate, calendar: calendar)

        // La séquence de semaines est ancrée à la création (§5.2bis) : la
        // règle « la semaine en cours ne reçoit des cibles que s'il y reste
        // assez de jours pour les trois séances cœur » s'évalue sur
        // `goal.createdAt`, pas sur `today`.
        let creationMonday = monday(of: goal.createdAt, calendar: calendar)
        let creationWeekTakesTargets =
            daysRemainingInWeek(from: goal.createdAt, calendar: calendar) >= minimumDaysForTargets
        let firstMonday = firstBuildMonday(goal: goal, calendar: calendar)

        var mondays: [Date] = []
        var cursor = firstMonday
        while cursor <= raceMonday {
            mondays.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 7, to: cursor)!
        }

        // Base d'ancrage : la charge mesurée strictement avant la première
        // semaine de construction. Le facteur de rampe s'en déduit une fois
        // pour toutes — pas une fois par semaine — pour que le plan ne
        // change pas de régime au fil des sorties. Calculée avant la garde
        // `mondays.isEmpty` ci-dessous : elle est exposée sur `TrainingPlan`
        // même quand le plan ne contient aucune semaine de cibles.
        let anchorBase = max(measuredBaseKm(history: runs, before: firstMonday, calendar: calendar),
                             minimumStartVolumeKm)
        let factor = anchorBase < goal.distanceKm ? comebackRampFactor : steadyRampFactor

        var weeks: [PlannedWeek] = []
        // La semaine de création trop entamée n'est affichée que pendant
        // cette semaine-là : une fois passée, il n'y a plus rien à clore.
        // (`firstMonday == creationMonday` est le repli « samedi avant la
        // course » : cette semaine est alors une vraie semaine du plan.)
        if !creationWeekTakesTargets, currentMonday == creationMonday, firstMonday != creationMonday {
            weeks.append(PlannedWeek(monday: creationMonday, role: .currentWeekClosing,
                                     targetKm: 0, sessions: []))
        }
        guard !mondays.isEmpty else {
            return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax, isMaintenance: false,
                                anchorBaseKm: anchorBase, rampFactor: factor)
        }

        let volumeCap = goal.distanceKm * peakVolumeMultiplier

        // Même ancrage pour la graine de sortie longue : lue avant la
        // première semaine, puis repliée en avant. Sinon les cibles de
        // sortie longue rebougeraient chaque jour, pour exactement la même
        // raison que les volumes.
        let anchorDayBefore = calendar.date(byAdding: .day, value: -1, to: firstMonday)!
        var previousLong = longestRecentRunKm(history: runs, today: anchorDayBefore, calendar: calendar)
        let peakClimb = min(maximumClimbM, goal.elevationGainM * 0.75)

        // Deux semaines ou moins **à la création** : trop tard pour
        // progresser, on entretient.
        if mondays.count <= 2 {
            for (i, monday) in mondays.enumerated() {
                let role: WeekRole = i == mondays.count - 1 ? .raceWeek : .taper
                let target = anchorBase * taperFactor
                let climb: Double = role == .raceWeek ? 0 : peakClimb * 0.5
                let weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                            climbTargetM: climb, goal: goal, hrMax: hrMax)
                if let long = weekSessions.first(where: { $0.kind == .longRun }) { previousLong = long.targetKm }
                weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target, sessions: weekSessions))
            }
            return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax, isMaintenance: true,
                                anchorBaseKm: anchorBase, rampFactor: factor)
        }

        // Le pic est à course − 2 ; on monte jusqu'à lui, puis on relâche.
        let peakIndex = mondays.count - 3
        var previousTarget = 0.0
        var peakVolume = anchorBase
        for (i, monday) in mondays.enumerated() {
            let role: WeekRole
            let target: Double
            if i <= peakIndex {
                let base: Double
                if i == 0 {
                    base = anchorBase
                } else if monday <= currentMonday {
                    // Semaine passée ou en cours : on relit la charge
                    // d'avant son lundi, plafonnée par la cible précédente.
                    // C'est la règle du non-rattrapage : une semaine courue
                    // court re-base les suivantes vers le bas, une semaine
                    // dépassée ne les remonte pas.
                    base = min(measuredBaseKm(history: runs, before: monday, calendar: calendar),
                               previousTarget)
                } else {
                    // Semaine à venir : projection pure, **aucune lecture de
                    // charge**. Une semaine qui n'a pas commencé n'a pas de
                    // « charge d'avant son lundi » ; y substituer celle
                    // d'aujourd'hui ferait bouger tout l'aperçu à chaque
                    // sortie — le défaut d'origine, déplacé.
                    base = previousTarget
                }
                target = min(base * factor, volumeCap)
                role = i == peakIndex ? .peak : .build
                if i == peakIndex { peakVolume = target }
            } else if i == mondays.count - 1 {
                role = .raceWeek
                target = peakVolume * raceWeekFactor
            } else {
                role = .taper
                target = peakVolume * taperFactor
            }
            let climb: Double
            switch role {
            case .peak:      climb = peakClimb
            case .build:     climb = firstWeekClimbM
                                    + (peakClimb - firstWeekClimbM) * Double(i) / Double(max(peakIndex, 1))
            case .taper:     climb = peakClimb * 0.5
            default:         climb = 0
            }
            let weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                        climbTargetM: climb, goal: goal, hrMax: hrMax)
            if let long = weekSessions.first(where: { $0.kind == .longRun }) { previousLong = long.targetKm }
            previousTarget = target
            weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target, sessions: weekSessions))
        }
        return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax, isMaintenance: false,
                            anchorBaseKm: anchorBase, rampFactor: factor)
    }
}

extension TrainingPlanner {
    static let longRunShare = 0.60
    static let hillsShare = 0.25
    static let longRunWeeklyGrowthKm = 2.5
    static let minimumBaseKm = 3.0
    static let defaultPreviousLongKm = 5.0
    static let firstWeekClimbM = 100.0
    static let maximumClimbM = 300.0

    static func hrRange(_ low: Double, _ high: Double, hrMax: Double) -> ClosedRange<Double> {
        (hrMax * low)...(hrMax * high)
    }

    /// Plus longue sortie des 14 derniers jours, `today` compris. La borne
    /// haute est **exclusive comme celle de `sumKm`** : sans elle, décaler
    /// la date d'ancrage ne suffirait pas — les sorties postérieures
    /// fuiraient dans la graine et les cibles de sortie longue rebougeraient
    /// chaque jour (§5.2bis).
    static func longestRecentRunKm(history: [Workout], today: Date, calendar: Calendar) -> Double {
        let endExclusive = calendar.date(byAdding: .day, value: 1,
                                         to: calendar.startOfDay(for: today))!
        let start = calendar.date(byAdding: .day, value: -14, to: endExclusive)!
        let recent = history
            .filter { $0.activityType == runningActivityType
                      && $0.startDate >= start && $0.startDate < endExclusive }
            .map(distanceKm)
        return recent.max() ?? defaultPreviousLongKm
    }

    /// Le motif de la séance : ce qu'elle entraîne et pourquoi elle existe,
    /// distinct de `note` (l'instruction). Ne dépend que du genre et — pour
    /// la sortie longue seulement — du rôle de la semaine : une sortie
    /// longue en semaine de pic ne se justifie pas comme une sortie longue
    /// allégée en affûtage.
    static func rationale(for kind: SessionKind, isTaper: Bool) -> String {
        switch kind {
        case .longRun:
            return isTaper
                ? "Allégée volontairement. À ce stade, entretenir suffit : ce que vous gagnez maintenant, c'est de la fraîcheur, pas de la forme."
                : "Elle construit votre distance : plus de capillaires, plus de mitochondries, une meilleure utilisation des graisses comme carburant. C'est 60 % du volume de la semaine — la séance à ne jamais sacrifier."
        case .hills:
            return "La seule séance dure de la semaine, et la seule qui prépare le dénivelé du parcours. La descente compte autant que la montée : c'est elle qui use les quadriceps en course."
        case .baseEndurance:
            return "Du volume à bas coût : du kilométrage sans fatigue supplémentaire, pour que la sortie longue et les côtes restent des séances de qualité. C'est celle que tout le monde court trop vite."
        case .optionalEasy:
            return "Elle absorbe les bonnes semaines, elle ne rattrape pas les mauvaises. À ne faire que si les trois autres sont faites."
        case .legOpener:
            return "Réveiller les jambes sans les fatiguer. Les accélérations sont courtes — quelques dizaines de secondes, pas du fractionné."
        }
    }

    static func sessions(role: WeekRole, targetKm: Double, previousLongKm: Double,
                         climbTargetM: Double, goal: RaceGoal, hrMax: Double) -> [PlannedSession] {
        let isTaper = role == .taper || role == .raceWeek
        var longKm = min(targetKm * longRunShare,
                         previousLongKm + longRunWeeklyGrowthKm,
                         min(14.0, goal.distanceKm * 0.8))
        if isTaper { longKm = min(longKm, goal.distanceKm * 0.4) }

        let easy = hrRange(0.60, 0.75, hrMax: hrMax)
        let endurance = hrRange(0.70, 0.80, hrMax: hrMax)
        let hard = hrRange(0.85, 0.92, hrMax: hrMax)

        var result = [
            PlannedSession(kind: .longRun, targetKm: longKm, targetMinutes: nil,
                           targetClimbM: 0, hrRange: isTaper ? easy : endurance,
                           note: isTaper
                               ? "Sortie longue allégée — restez très à l'aise."
                               : "Sortie longue : la séance qui construit votre distance. Allure conversation.",
                           rationale: rationale(for: .longRun, isTaper: isTaper))
        ]

        if role == .raceWeek {
            result.append(PlannedSession(kind: .legOpener, targetKm: 0, targetMinutes: 15,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Déverrouillage : 15 min souples avec deux ou trois accélérations courtes.",
                                         rationale: rationale(for: .legOpener, isTaper: isTaper)))
        } else {
            result.append(PlannedSession(kind: .hills, targetKm: targetKm * hillsShare,
                                         targetMinutes: nil, targetClimbM: climbTargetM,
                                         hrRange: isTaper ? endurance : hard,
                                         note: "Parcours vallonné, visez environ \(Int(climbTargetM.rounded())) m de dénivelé positif.",
                                         rationale: rationale(for: .hills, isTaper: isTaper)))
        }

        let used = result.reduce(0) { $0 + $1.targetKm }
        result.append(PlannedSession(kind: .baseEndurance,
                                     targetKm: max(targetKm - used, minimumBaseKm),
                                     targetMinutes: nil, targetClimbM: 0, hrRange: easy,
                                     note: "Endurance fondamentale : facile, vraiment facile.",
                                     rationale: rationale(for: .baseEndurance, isTaper: isTaper)))

        if !isTaper {
            result.append(PlannedSession(kind: .optionalEasy, targetKm: 0, targetMinutes: 30,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Optionnelle : 30 min faciles, seulement si les trois autres séances sont faites et que vous vous sentez bien.",
                                         rationale: rationale(for: .optionalEasy, isTaper: isTaper)))
        }
        return result
    }
}
