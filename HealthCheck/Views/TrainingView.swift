import SwiftUI

struct TrainingView: View {
    @ObservedObject var viewModel: TrainingViewModel

    @State private var goalName = ""
    @State private var goalRaceDate = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    @State private var goalDistanceText = ""
    @State private var goalClimbText = ""

    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let goal = viewModel.goal, let plan = viewModel.plan {
                    goalCard(goal: goal, plan: plan)
                    if let next = nextGoalAfterActive {
                        Text("Objectif suivant : \(next.name), le \(raceDateText(next.raceDate)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let progress = viewModel.progress {
                        thisWeekSection(progress)
                    }
                    if let assessment = viewModel.assessment {
                        loadSection(assessment)
                    }
                    upcomingWeeksSection(plan)
                    deleteSection
                } else {
                    emptyState
                    if let assessment = viewModel.assessment {
                        loadSection(assessment)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Supprimer cet objectif ?", isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { deleteGoal() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le plan associé disparaîtra. Cette action est irréversible.")
        }
    }

    // MARK: - État vide

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            ContentUnavailableView(
                "Aucun objectif de course",
                systemImage: "target",
                description: Text("Créez un objectif pour obtenir un plan d'entraînement personnalisé.")
            )
            .frame(maxWidth: .infinity)
            createGoalForm
        }
    }

    private var createGoalForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Créer un objectif").font(.title2.bold())

            TextField("Nom de la course", text: $goalName)
                .textFieldStyle(.roundedBorder)

            DatePicker("Date de la course", selection: $goalRaceDate, in: Date()...,
                      displayedComponents: .date)

            HStack(spacing: 12) {
                TextField("Distance (km)", text: $goalDistanceText)
                    .textFieldStyle(.roundedBorder)
                TextField("Dénivelé positif (m)", text: $goalClimbText)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Créer") { createGoal() }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateGoal)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: 460)
    }

    private var parsedDistanceKm: Double {
        Double(goalDistanceText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var parsedClimbM: Double {
        Double(goalClimbText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canCreateGoal: Bool {
        !goalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedDistanceKm > 0
            && goalRaceDate > Date()
    }

    private func createGoal() {
        do {
            try viewModel.createGoal(name: goalName.trimmingCharacters(in: .whitespacesAndNewlines),
                                     raceDate: goalRaceDate, distanceKm: parsedDistanceKm,
                                     elevationGainM: parsedClimbM)
            try viewModel.load()
            goalName = ""
            goalDistanceText = ""
            goalClimbText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteGoal() {
        do {
            try viewModel.deleteActiveGoal()
            try viewModel.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Objectif actif

    @ViewBuilder
    private func goalCard(goal: RaceGoal, plan: TrainingPlan) -> some View {
        let currentMonday = TrainingPlanner.monday(of: Date(), calendar: .current)
        // Seules les semaines porteuses de cibles sont numérotées : la
        // semaine de clôture n'en est pas une. Si aujourd'hui ne tombe dans
        // aucune d'elles, la ligne est omise plutôt que fausse.
        let targetWeeks = plan.weeks.filter { $0.role != .currentWeekClosing }
        let weekIndex = targetWeeks.firstIndex { $0.monday == currentMonday }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(goal.name).font(.title2.bold())
                    Text(countdownText(to: goal.raceDate))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.teal)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                statText("\(goal.distanceKm.formatted(.number.precision(.fractionLength(1)))) km", icon: "location.fill")
                statText("D+ \(Int(goal.elevationGainM.rounded())) m", icon: "mountain.2.fill")
                if let weekIndex {
                    statText("Semaine \(weekIndex + 1) sur \(targetWeeks.count)", icon: "calendar")
                }
            }
            if plan.isMaintenance {
                Text("Trop tard pour progresser — plan de maintien")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Deuxième course à venir, s'il y en a une : la v1 ne planifie que la
    /// plus proche, mais elle ne doit pas faire comme si l'autre n'existait pas.
    private var nextGoalAfterActive: RaceGoal? {
        viewModel.upcomingGoals.count > 1 ? viewModel.upcomingGoals[1] : nil
    }

    private func raceDateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
    }

    private func countdownText(to raceDate: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
            from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: raceDate)).day ?? 0
        return "J\u{2212}\(days)"
    }

    // MARK: - Cette semaine

    private func thisWeekSection(_ progress: WeekProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cette semaine").font(.title2.bold())
            VStack(spacing: 8) {
                ForEach(Array(progress.matched.enumerated()), id: \.offset) { _, matched in
                    matchedSessionRow(matched)
                }
                ForEach(Array(progress.offPlan.enumerated()), id: \.offset) { _, workout in
                    offPlanRow(workout)
                }
            }
        }
    }

    @ViewBuilder
    private func matchedSessionRow(_ matched: MatchedSession) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionLabel(matched.session.kind)).font(.callout.weight(.semibold))
                Text(matched.session.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(targetText(matched.session)).font(.callout.monospacedDigit())
                Text(bpmRangeText(matched.session.hrRange))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            doneBadge(isDone: matched.isDone)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4)))
    }

    @ViewBuilder
    private func offPlanRow(_ workout: Workout) -> some View {
        let label = WorkoutStatsEngine.label(for: workout.activityType)
        HStack(spacing: 14) {
            Image(systemName: WorkoutStatsEngine.icon(for: label))
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(label).font(.callout.weight(.semibold))
            Spacer()
            Text(TrainingPlanner.distanceKm(workout).formatted(.number.precision(.fractionLength(1))) + " km")
                .font(.callout.monospacedDigit())
            Text("hors plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.secondary.opacity(0.12), in: Capsule())
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4)))
    }

    @ViewBuilder
    private func doneBadge(isDone: Bool) -> some View {
        Label(isDone ? "Fait" : "À faire", systemImage: isDone ? "checkmark.circle.fill" : "circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isDone ? Color.green : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((isDone ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }

    private func sessionLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "Sortie longue"
        case .hills: return "Côtes"
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

    private func bpmRangeText(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) bpm"
    }

    // MARK: - Charge

    private func loadSection(_ assessment: LoadAssessment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Charge").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)], spacing: 12) {
                MetricCard(style: .acuteLoad,
                          value: assessment.acuteKm.formatted(.number.precision(.fractionLength(1))))
                MetricCard(style: .chronicLoad,
                          value: assessment.chronicWeeklyKm.formatted(.number.precision(.fractionLength(1))))
                if let acwr = assessment.acwr {
                    MetricCard(style: .loadRatio, value: acwr.formatted(.number.precision(.fractionLength(2))))
                }
            }
            if !assessment.alerts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(assessment.alerts.enumerated()), id: \.offset) { _, alert in
                        Label(alert.message,
                             systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.callout)
                            .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
                    }
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            }
        }
    }

    // MARK: - Semaines suivantes

    private func upcomingWeeksSection(_ plan: TrainingPlan) -> some View {
        let currentMonday = TrainingPlanner.monday(of: Date(), calendar: .current)
        let upcoming = plan.weeks.filter { $0.monday > currentMonday }
        return Group {
            if !upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Semaines suivantes").font(.title2.bold())
                    VStack(spacing: 8) {
                        ForEach(Array(upcoming.enumerated()), id: \.offset) { _, week in
                            upcomingWeekRow(week)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func upcomingWeekRow(_ week: PlannedWeek) -> some View {
        let longRun = week.sessions.first { $0.kind == .longRun }
        let hills = week.sessions.first { $0.kind == .hills }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(week.monday.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                    .font(.callout.weight(.semibold))
                Text(roleLabel(week.role)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 16) {
                statText(week.targetKm.formatted(.number.precision(.fractionLength(1))) + " km", icon: "figure.run")
                if let longRun {
                    statText(longRun.targetKm.formatted(.number.precision(.fractionLength(1))) + " km",
                            icon: "arrow.up.forward")
                }
                if let hills, hills.targetClimbM > 0 {
                    statText("D+ \(Int(hills.targetClimbM.rounded())) m", icon: "mountain.2")
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4)))
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

    // MARK: - Suppression

    private var deleteSection: some View {
        Button("Supprimer l'objectif", role: .destructive) {
            showingDeleteConfirmation = true
        }
        .padding(.top, 8)
    }

    // MARK: - Commun

    @ViewBuilder
    private func statText(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}
