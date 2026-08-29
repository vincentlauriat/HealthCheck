import Foundation

protocol TrainingPlanProviding {
    func currentTrainingPlan() throws -> TrainingPlanResponse
}

struct TrainingPlanProvider: TrainingPlanProviding {
    private static let historyWindowDays = 90
    private static let foldLookbackDays = 28
    private static let hrMaxWindowDays = 180
    private static let heartRateType = "HKQuantityTypeIdentifierHeartRate"
    private static let defaultHRMax = 190.0

    private let store: HealthStore
    private let calendar: Calendar
    private let now: () -> Date

    init(store: HealthStore, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    func currentTrainingPlan() throws -> TrainingPlanResponse {
        let today = now()
        let goals = try store.raceGoals()
        guard let goal = RaceGoal.active(in: goals, today: today, calendar: calendar) else {
            return TrainingPlanResponse(
                generatedAt: today,
                goal: nil,
                weeks: [],
                message: "Aucun objectif de course actif. Créez un objectif sur le Mac pour afficher un plan ici."
            )
        }

        let historyStart = self.historyStart(for: goal, today: today)
        let history = try store.workouts(from: historyStart, to: today)
        let hrMaxCutoff = calendar.date(byAdding: .day, value: -Self.hrMaxWindowDays, to: today)!
        let hrMax = (try? store.maxValue(type: Self.heartRateType, from: hrMaxCutoff, to: today))
            .flatMap { $0 } ?? Self.defaultHRMax
        let plan = TrainingPlanner.plan(goal: goal, history: history, hrMax: hrMax, today: today, calendar: calendar)

        return TrainingPlanResponse(
            generatedAt: today,
            goal: TrainingGoalSummary(
                name: goal.name,
                raceDate: goal.raceDate,
                distanceKm: goal.distanceKm,
                elevationGainM: goal.elevationGainM
            ),
            weeks: plan.weeks.map { weekSummary($0, hrMax: plan.hrMax) },
            message: nil
        )
    }

    private func historyStart(for goal: RaceGoal, today: Date) -> Date {
        let defaultStart = calendar.date(byAdding: .day, value: -Self.historyWindowDays, to: today)!
        let firstMonday = TrainingPlanner.firstBuildMonday(goal: goal, calendar: calendar)
        let foldStart = calendar.date(byAdding: .day, value: -Self.foldLookbackDays, to: firstMonday)!
        return min(defaultStart, foldStart)
    }

    private func weekSummary(_ week: PlannedWeek, hrMax: Double) -> TrainingWeekSummary {
        TrainingWeekSummary(
            monday: week.monday,
            role: roleLabel(week.role),
            targetKm: week.targetKm,
            sessions: week.sessions.map { sessionSummary($0, hrMax: hrMax) }
        )
    }

    private func sessionSummary(_ session: PlannedSession, hrMax: Double) -> TrainingSessionSummary {
        TrainingSessionSummary(
            kind: sessionLabel(session.kind),
            targetText: targetText(session),
            detailText: bpmRangeText(session.hrRange, hrMax: hrMax, kind: session.kind),
            note: session.note,
            rationale: session.rationale,
            isOptional: session.isOptional
        )
    }

    private func roleLabel(_ role: WeekRole) -> String {
        switch role {
        case .currentWeekClosing: return "Semaine en cours"
        case .build: return "Construction"
        case .peak: return "Pic"
        case .taper: return "Affûtage"
        case .raceWeek: return "Semaine de course"
        }
    }

    private func sessionLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "Sortie longue"
        case .hills: return "Côtes"
        case .vo2MaxIntervals: return "Intervalles VO2max"
        case .baseEndurance: return "Endurance"
        case .optionalEasy: return "Optionnelle"
        case .legOpener: return "Déverrouillage"
        }
    }

    private func targetText(_ session: PlannedSession) -> String {
        if session.targetKm > 0 {
            return session.targetKm.formatted(.number.precision(.fractionLength(1))) + " km"
        }
        if let minutes = session.targetMinutes {
            return "\(Int(minutes.rounded())) min"
        }
        return ""
    }

    private func bpmRangeText(_ range: ClosedRange<Double>, hrMax: Double, kind: SessionKind) -> String {
        let low = Int(range.lowerBound.rounded())
        let high = Int(range.upperBound.rounded())
        let pctLow = Int((range.lowerBound / hrMax * 100).rounded())
        let pctHigh = Int((range.upperBound / hrMax * 100).rounded())
        return "\(low)-\(high) bpm · \(pctLow)-\(pctHigh) % FC max · \(intensityLabel(kind))"
    }

    private func intensityLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "endurance"
        case .hills, .vo2MaxIntervals: return "intensité"
        case .baseEndurance, .optionalEasy: return "récupération active"
        case .legOpener: return "réveil"
        }
    }
}
