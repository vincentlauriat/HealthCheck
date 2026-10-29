import Foundation

/// Rôle d'une semaine dans la préparation.
enum WeekRole: Equatable {
    case currentWeekClosing  // semaine en cours trop entamée pour recevoir des cibles
    case build
    case recovery            // semaine allégée : cycle 3 + 1, ou lendemain d'une course longue
    case tuneUp              // semaine d'une course de préparation
    case peak                // course − 2
    case taper               // course − 1
    case raceWeek
}

enum SessionKind: Equatable {
    case longRun
    case hills
    case vo2MaxIntervals
    case baseEndurance
    case optionalEasy
    case legOpener
    case tuneUpRace          // la course de préparation elle-même
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
    /// Course de préparation courue cette semaine-là, s'il y en a une.
    /// Renseignée quel que soit le rôle : une course qui tombe en semaine
    /// de pic ou d'affûtage remplace sa sortie longue sans changer le rôle.
    let tuneUp: RaceGoal?

    init(monday: Date, role: WeekRole, targetKm: Double, sessions: [PlannedSession],
         tuneUp: RaceGoal? = nil) {
        self.monday = monday
        self.role = role
        self.targetKm = targetKm
        self.sessions = sessions
        self.tuneUp = tuneUp
    }
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
    /// Volume hebdomadaire que la montée ne dépasse pas : calculé
    /// (`TrainingPlanner.volumeCapKm`) ou choisi par l'utilisateur.
    let volumeCapKm: Double

    /// Vrai quand le plafond vient de l'utilisateur et non du calcul.
    var isVolumeCapOverridden: Bool { goal.peakWeeklyKmOverride != nil }

    /// Plus longue sortie longue du plan, toutes semaines confondues.
    /// Calculée, pas stockée : elle ne peut pas se désynchroniser des
    /// séances réellement produites.
    var longestPlannedRunKm: Double {
        weeks.flatMap(\.sessions)
            .filter { $0.kind == .longRun }
            .map(\.targetKm)
            .max() ?? 0
    }

    /// Nombre de semaines qui montent (construction + pic), semaine de
    /// clôture exclue puisqu'elle ne porte aucune cible. Dépend de la
    /// distance à la course — un plan plus long a plus de semaines de
    /// montée — donc calculé, jamais recopié dans une phrase figée.
    var rampWeekCount: Int {
        weeks.filter { $0.role == .build || $0.role == .peak }.count
    }

    /// Nombre de semaines qui redescendent (affûtage + semaine de course).
    var taperWeekCount: Int {
        weeks.filter { $0.role == .taper || $0.role == .raceWeek }.count
    }

    /// Semaines allégées insérées dans la montée (cycle 3 + 1 ou
    /// récupération après une course de préparation longue).
    var recoveryWeekCount: Int {
        weeks.filter { $0.role == .recovery }.count
    }

    /// Courses de préparation que le plan intègre, toutes semaines confondues.
    var tuneUpRaces: [RaceGoal] {
        weeks.compactMap(\.tuneUp)
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
    /// estimation à 7:00/km à partir de la durée. Le même repli partout —
    /// deux définitions laisseraient le planificateur et le moniteur lire
    /// des charges différentes pour le même historique. Sans distance
    /// mesurée **et** sans durée exploitable (unité non reconnue), la
    /// séance contribue 0 km plutôt qu'un chiffre fabriqué à partir d'une
    /// unité qu'on ne comprend pas — un 0 rate silencieusement une séance,
    /// une distance inventée fausserait la base d'ancrage du plan.
    ///
    /// La distance passe par `WorkoutStatsEngine.distanceKilometres` : la
    /// lire brute prendrait des mètres pour des kilomètres.
    static func distanceKm(_ workout: Workout) -> Double {
        if let km = WorkoutStatsEngine.distanceKilometres(workout) { return km }
        guard let minutes = WorkoutStatsEngine.durationMinutes(workout) else { return 0 }
        return minutes / fallbackPaceMinutesPerKm
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

    // MARK: - Plafonds

    /// Plafond de volume de la montée. Choisi par l'utilisateur s'il l'a
    /// fixé — appliqué tel quel, sans borne : c'est son plan. Sinon
    /// 1,5 × le kilomètre-effort de la course (la distance seule
    /// sous-estimait une course à dénivelé), et **jamais sous la base
    /// mesurée** : un coureur déjà au-dessus ne se voit pas demander de
    /// courir moins au pic qu'il ne court aujourd'hui.
    static func volumeCapKm(goal: RaceGoal, anchorBaseKm: Double) -> Double {
        if let override = goal.peakWeeklyKmOverride, override > 0 { return override }
        return max(goal.effortKm * peakVolumeMultiplier, anchorBaseKm)
    }

    /// Plafond de la sortie longue. Jusqu'au semi, la distance de course
    /// elle-même : la courir à l'entraînement, à allure conversation, est
    /// l'usage courant et rassure le jour J. Au-delà, 75 % de la distance,
    /// borné à 32 km — ce qui dépasse s'use plus qu'il ne construit.
    static func longRunCapKm(goal: RaceGoal) -> Double {
        if goal.distanceKm <= halfMarathonKm { return goal.distanceKm }
        return min(goal.distanceKm * longRaceLongRunShare, maximumLongRunKm)
    }

    // MARK: - Plan

    static func plan(goal: RaceGoal, tuneUps: [RaceGoal] = [], history: [Workout], hrMax: Double,
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
        let volumeCap = volumeCapKm(goal: goal, anchorBaseKm: anchorBase)

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
                                anchorBaseKm: anchorBase, rampFactor: factor, volumeCapKm: volumeCap)
        }

        // Une course de préparation par semaine au plus (la première si
        // deux tombent la même semaine), jamais la semaine de la course
        // principale : celle-ci a déjà son propre allègement.
        var tuneUpByMonday: [Date: RaceGoal] = [:]
        for race in tuneUps.sorted(by: { $0.raceDate < $1.raceDate }) {
            let raceWeekMonday = monday(of: race.raceDate, calendar: calendar)
            guard raceWeekMonday >= firstMonday, raceWeekMonday < raceMonday,
                  tuneUpByMonday[raceWeekMonday] == nil else { continue }
            tuneUpByMonday[raceWeekMonday] = race
        }

        // Même ancrage pour la graine de sortie longue : lue avant la
        // première semaine, puis repliée en avant. Sinon les cibles de
        // sortie longue rebougeraient chaque jour, pour exactement la même
        // raison que les volumes.
        let anchorDayBefore = calendar.date(byAdding: .day, value: -1, to: firstMonday)!
        var previousLong = longestRecentRunKm(history: runs, today: anchorDayBefore, calendar: calendar)
        // Plus de plafond absolu de 300 m : le dénivelé de la séance dédiée
        // suit celui de la course, quel qu'il soit.
        let peakClimb = goal.elevationGainM * peakClimbShare
        let firstClimb = min(firstWeekClimbM, peakClimb)

        // Deux semaines ou moins **à la création** : trop tard pour
        // progresser, on entretient.
        if mondays.count <= 2 {
            for (i, monday) in mondays.enumerated() {
                let role: WeekRole = i == mondays.count - 1 ? .raceWeek : .taper
                // `role` peut être `.raceWeek` ici, mais la cible reste
                // `taperFactor` (0.75) et non `raceWeekFactor` (0.5) — c'est
                // délibéré. `raceWeekFactor` réduit de moitié le volume de
                // *pic* pour la semaine de course ; cette branche n'a jamais
                // eu de semaine de pic dont redescendre, donc rien dont
                // `raceWeekFactor` pourrait prendre la moitié. Le nom du
                // rôle sert à l'affichage (« semaine de course »), pas au
                // calcul de la cible. Ne pas « corriger » ce facteur sans
                // relire `test_plan_raceTooClose_isTaperOnlyAndNeverRamps`.
                let target = anchorBase * taperFactor
                let climb: Double = role == .raceWeek ? 0 : peakClimb * 0.5
                let tuneUp = tuneUpByMonday[monday]
                var weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                            climbTargetM: climb, goal: goal, hrMax: hrMax,
                                            weekIndexInRamp: nil)
                if let long = weekSessions.first(where: { $0.kind == .longRun }) { previousLong = long.targetKm }
                if let tuneUp { weekSessions = replacingLongRun(weekSessions, with: tuneUp, hrMax: hrMax) }
                weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target,
                                         sessions: weekSessions, tuneUp: tuneUp))
            }
            return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax, isMaintenance: true,
                                anchorBaseKm: anchorBase, rampFactor: factor, volumeCapKm: volumeCap)
        }

        // Le pic est à course − 2 ; on monte jusqu'à lui, puis on relâche.
        let peakIndex = mondays.count - 3
        // Dernière cible de **montée** : les semaines allégées et les
        // semaines de course de préparation n'y touchent pas. La montée
        // reprend donc là où elle s'était arrêtée au lieu de repartir du
        // creux — sans quoi chaque récupération coûterait trois semaines.
        var lastRampTarget: Double?
        var peakVolume = anchorBase
        var buildStreak = 0
        var recoveryOwed = false
        for (i, monday) in mondays.enumerated() {
            let tuneUp = tuneUpByMonday[monday]
            let reference = lastRampTarget ?? anchorBase
            let role: WeekRole
            let target: Double
            if i <= peakIndex {
                if let tuneUp, i < peakIndex {
                    // La course compte pour la sortie longue : la semaine est
                    // allégée autour, mais jamais au point de ne pas contenir
                    // la course elle-même plus un footing.
                    role = .tuneUp
                    target = max(reference * tuneUpWeekFactor, tuneUp.distanceKm + minimumBaseKm)
                    buildStreak = 0
                    recoveryOwed = tuneUp.effortKm >= recoveryAfterRaceEffortKm
                } else if i < peakIndex,
                          recoveryOwed || (buildStreak >= buildWeeksPerCycle && i < peakIndex - 1) {
                    // Cycle 3 + 1 : trois semaines qui montent, une qui
                    // allège. Jamais la semaine qui précède le pic — on
                    // arrive au pic sur une montée — ni le pic lui-même.
                    role = .recovery
                    target = reference * recoveryFactor
                    buildStreak = 0
                    recoveryOwed = false
                } else {
                    let base: Double
                    if lastRampTarget == nil {
                        base = anchorBase
                    } else if monday <= currentMonday {
                        // Semaine passée ou en cours : on relit la charge
                        // d'avant son lundi, plafonnée par la dernière cible
                        // de montée. C'est la règle du non-rattrapage : une
                        // semaine courue court re-base les suivantes vers le
                        // bas, une semaine dépassée ne les remonte pas.
                        base = min(measuredBaseKm(history: runs, before: monday, calendar: calendar),
                                   reference)
                    } else {
                        // Semaine à venir : projection pure, **aucune lecture de
                        // charge**. Une semaine qui n'a pas commencé n'a pas de
                        // « charge d'avant son lundi » ; y substituer celle
                        // d'aujourd'hui ferait bouger tout l'aperçu à chaque
                        // sortie — le défaut d'origine, déplacé.
                        base = reference
                    }
                    target = min(base * factor, volumeCap)
                    role = i == peakIndex ? .peak : .build
                    if i == peakIndex { peakVolume = target }
                    lastRampTarget = target
                    buildStreak += 1
                }
            } else if i == mondays.count - 1 {
                role = .raceWeek
                target = peakVolume * raceWeekFactor
            } else {
                role = .taper
                target = peakVolume * taperFactor
            }
            let rampClimb = firstClimb + (peakClimb - firstClimb) * Double(i) / Double(max(peakIndex, 1))
            let climb: Double
            switch role {
            case .peak:      climb = peakClimb
            case .build:     climb = rampClimb
            case .recovery:  climb = rampClimb * 0.5
            case .taper:     climb = peakClimb * 0.5
            default:         climb = 0
            }
            var weekSessions = sessions(role: role, targetKm: target, previousLongKm: previousLong,
                                        climbTargetM: climb, goal: goal, hrMax: hrMax,
                                        weekIndexInRamp: i <= peakIndex ? i : nil, tuneUp: tuneUp)
            // La progression de la sortie longue ne se lit que sur les
            // semaines qui la portent vraiment : une semaine allégée ou de
            // course ne la fait ni reculer ni avancer.
            if role != .recovery, role != .tuneUp,
               let long = weekSessions.first(where: { $0.kind == .longRun }) {
                previousLong = long.targetKm
            }
            if let tuneUp, role != .tuneUp {
                weekSessions = replacingLongRun(weekSessions, with: tuneUp, hrMax: hrMax)
            }
            weeks.append(PlannedWeek(monday: monday, role: role, targetKm: target,
                                     sessions: weekSessions, tuneUp: tuneUp))
        }
        return TrainingPlan(goal: goal, weeks: weeks, hrMax: hrMax, isMaintenance: false,
                            anchorBaseKm: anchorBase, rampFactor: factor, volumeCapKm: volumeCap)
    }
}

extension TrainingPlanner {
    static let longRunShare = 0.60
    static let hillsShare = 0.25
    static let longRunWeeklyGrowthKm = 2.5
    static let minimumBaseKm = 3.0
    static let defaultPreviousLongKm = 5.0
    static let firstWeekClimbM = 100.0
    /// Part du D+ de la course visée par la séance de côtes au pic.
    static let peakClimbShare = 0.75

    // Saison et périodisation (spec 2026-10-29 season planning).
    /// Semaines de montée consécutives avant une semaine allégée (3 + 1).
    static let buildWeeksPerCycle = 3
    /// Volume d'une semaine allégée, en part de la dernière cible de montée.
    static let recoveryFactor = 0.70
    /// Sortie longue d'une semaine allégée, en part de la précédente.
    static let recoveryLongRunFactor = 0.70
    /// Volume d'une semaine de course de préparation, en part de la
    /// dernière cible de montée (plancher : la course + un footing).
    static let tuneUpWeekFactor = 0.85
    /// Une course de préparation d'au moins 15 km-effort est suivie d'une
    /// semaine allégée ; un 10 km plat ne l'est pas.
    static let recoveryAfterRaceEffortKm = 15.0
    /// Gradient à partir duquel la course est un trail : la sortie longue
    /// porte alors elle aussi du dénivelé.
    static let trailGradientMPerKm = 30.0
    static let halfMarathonKm = 21.1
    static let longRaceLongRunShare = 0.75
    static let maximumLongRunKm = 32.0

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
    static func rationale(for kind: SessionKind, isTaper: Bool, isRecovery: Bool = false) -> String {
        switch kind {
        case .longRun:
            if isRecovery {
                return "Semaine allégée : l'organisme assimile la charge (ou la course) qui précède. C'est pendant ces semaines-là que la forme se fabrique — les sauter, c'est empiler de la fatigue."
            }
            return isTaper
                ? "Allégée volontairement. À ce stade, entretenir suffit : ce que vous gagnez maintenant, c'est de la fraîcheur, pas de la forme."
                : "Elle construit votre distance : plus de capillaires, plus de mitochondries, une meilleure utilisation des graisses comme carburant. C'est 60 % du volume de la semaine — la séance à ne jamais sacrifier."
        case .hills:
            return "La seule séance dure de la semaine, et la seule qui prépare le dénivelé du parcours. La descente compte autant que la montée : c'est elle qui use les quadriceps en course."
        case .vo2MaxIntervals:
            return "Les efforts proches du maximum sont ce qui fait progresser la VO2max le plus efficacement — les côtes travaillent la force, ceci travaille la capacité aérobie."
        case .baseEndurance:
            return "Du volume à bas coût : du kilométrage sans fatigue supplémentaire, pour que la sortie longue et les côtes restent des séances de qualité. C'est celle que tout le monde court trop vite."
        case .optionalEasy:
            return "Elle absorbe les bonnes semaines, elle ne rattrape pas les mauvaises. À ne faire que si les trois autres sont faites."
        case .legOpener:
            return "Réveiller les jambes sans les fatiguer. Les accélérations sont courtes — quelques dizaines de secondes, pas du fractionné."
        case .tuneUpRace:
            return "Une course sur le chemin vaut une sortie longue de qualité : le dossard, la gestion de l'effort, le ravitaillement en conditions réelles. Elle remplace la sortie longue de la semaine ; l'intensité, c'est vous qui la choisissez."
        }
    }

    /// La séance « course de préparation » : distance et D+ de la course,
    /// zone large — de la sortie longue au vrai test, au choix du coureur.
    static func raceSession(_ race: RaceGoal, hrMax: Double) -> PlannedSession {
        let km = race.distanceKm.formatted(.number.precision(.fractionLength(0...1))
            .locale(Locale(identifier: "fr_FR")))
        var note = "Course de préparation : \(race.name), \(km) km"
        if race.elevationGainM > 0 { note += " et \(Int(race.elevationGainM.rounded())) m de D+" }
        note += ". En sortie longue en course ou en vrai test : à vous de voir."
        return PlannedSession(kind: .tuneUpRace, targetKm: race.distanceKm, targetMinutes: nil,
                              targetClimbM: race.elevationGainM,
                              hrRange: hrRange(0.75, 0.95, hrMax: hrMax),
                              note: note,
                              rationale: rationale(for: .tuneUpRace, isTaper: false))
    }

    /// Une course qui tombe une semaine qui n'est pas la sienne (pic,
    /// affûtage, maintien) prend la place de la sortie longue : on ne
    /// court pas les deux.
    static func replacingLongRun(_ sessions: [PlannedSession], with race: RaceGoal,
                                 hrMax: Double) -> [PlannedSession] {
        let race = raceSession(race, hrMax: hrMax)
        guard let index = sessions.firstIndex(where: { $0.kind == .longRun }) else {
            return [race] + sessions
        }
        var result = sessions
        result[index] = race
        return result
    }

    static func sessions(role: WeekRole, targetKm: Double, previousLongKm: Double,
                         climbTargetM: Double, goal: RaceGoal, hrMax: Double,
                         weekIndexInRamp: Int? = nil, tuneUp: RaceGoal? = nil) -> [PlannedSession] {
        let isTaper = role == .taper || role == .raceWeek
        let isRecovery = role == .recovery

        let easy = hrRange(0.60, 0.75, hrMax: hrMax)
        let endurance = hrRange(0.70, 0.80, hrMax: hrMax)
        let hard = hrRange(0.85, 0.92, hrMax: hrMax)
        let intervals = hrRange(0.90, 0.97, hrMax: hrMax)

        // Semaine de course de préparation : la course tient lieu de sortie
        // longue, un déverrouillage la précède, le reste est facile.
        if role == .tuneUp, let tuneUp {
            let race = raceSession(tuneUp, hrMax: hrMax)
            return [
                race,
                PlannedSession(kind: .legOpener, targetKm: 0, targetMinutes: 15,
                               targetClimbM: 0, hrRange: easy,
                               note: "Déverrouillage, deux ou trois jours avant la course : 15 min souples avec quelques accélérations courtes.",
                               rationale: rationale(for: .legOpener, isTaper: true)),
                PlannedSession(kind: .baseEndurance,
                               targetKm: max(targetKm - race.targetKm, minimumBaseKm),
                               targetMinutes: nil, targetClimbM: 0, hrRange: easy,
                               note: "Endurance fondamentale : facile, vraiment facile. Plutôt après la course qu'avant.",
                               rationale: rationale(for: .baseEndurance, isTaper: true))
            ]
        }

        var longKm = min(targetKm * longRunShare,
                         previousLongKm + longRunWeeklyGrowthKm,
                         longRunCapKm(goal: goal))
        if isTaper { longKm = min(longKm, goal.distanceKm * 0.4) }
        if isRecovery {
            longKm = min(targetKm * longRunShare, previousLongKm * recoveryLongRunFactor)
        }

        // Sur un trail, la sortie longue porte le gradient de la course :
        // c'est elle qui habitue les jambes à enchaîner montées et descentes
        // sur la durée. Moitié moins en semaine allégée ou d'affûtage.
        let longClimb: Double = goal.isTrail
            ? longKm * goal.elevationGainM / goal.distanceKm * (isTaper || isRecovery ? 0.5 : 1)
            : 0
        let longNote: String
        if isRecovery {
            longNote = "Sortie longue raccourcie : semaine allégée, tout en aisance."
        } else if isTaper {
            longNote = "Sortie longue allégée — restez très à l'aise."
        } else {
            longNote = "Sortie longue : la séance qui construit votre distance. Allure conversation."
        }
        let longNoteWithClimb = longClimb > 0
            ? longNote + " Terrain vallonné : environ \(Int(longClimb.rounded())) m de D+, marcher dans les raides est permis."
            : longNote

        var result = [
            PlannedSession(kind: .longRun, targetKm: longKm, targetMinutes: nil,
                           targetClimbM: longClimb,
                           hrRange: isTaper || isRecovery ? easy : endurance,
                           note: longNoteWithClimb,
                           rationale: rationale(for: .longRun, isTaper: isTaper, isRecovery: isRecovery))
        ]

        if role == .raceWeek {
            result.append(PlannedSession(kind: .legOpener, targetKm: 0, targetMinutes: 15,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Déverrouillage : 15 min souples avec deux ou trois accélérations courtes.",
                                         rationale: rationale(for: .legOpener, isTaper: isTaper)))
        } else if !isRecovery {
            let usesIntervals: Bool
            if let index = weekIndexInRamp, role == .build {
                usesIntervals = index % 2 == 1
            } else {
                usesIntervals = false
            }
            if usesIntervals {
                result.append(PlannedSession(kind: .vo2MaxIntervals, targetKm: targetKm * hillsShare,
                                             targetMinutes: nil, targetClimbM: 0, hrRange: intervals,
                                             note: "Fractionné : répétitions courtes et rapides, séparées de récupérations. L'intensité compte plus que la distance — visez la zone indiquée.",
                                             rationale: rationale(for: .vo2MaxIntervals, isTaper: isTaper)))
            } else {
                result.append(PlannedSession(kind: .hills, targetKm: targetKm * hillsShare,
                                             targetMinutes: nil, targetClimbM: climbTargetM,
                                             hrRange: isTaper ? endurance : hard,
                                             note: "Parcours vallonné, visez environ \(Int(climbTargetM.rounded())) m de dénivelé positif.",
                                             rationale: rationale(for: .hills, isTaper: isTaper)))
            }
        }

        let used = result.reduce(0) { $0 + $1.targetKm }
        result.append(PlannedSession(kind: .baseEndurance,
                                     targetKm: max(targetKm - used, minimumBaseKm),
                                     targetMinutes: nil, targetClimbM: 0, hrRange: easy,
                                     note: "Endurance fondamentale : facile, vraiment facile.",
                                     rationale: rationale(for: .baseEndurance, isTaper: isTaper)))

        if !isTaper, !isRecovery {
            result.append(PlannedSession(kind: .optionalEasy, targetKm: 0, targetMinutes: 30,
                                         targetClimbM: 0, hrRange: easy,
                                         note: "Optionnelle : 30 min faciles, seulement si les trois autres séances sont faites et que vous vous sentez bien.",
                                         rationale: rationale(for: .optionalEasy, isTaper: isTaper)))
        }
        return result
    }
}
