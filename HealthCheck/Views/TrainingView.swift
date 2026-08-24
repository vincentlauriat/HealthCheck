import SwiftUI

struct TrainingView: View {
    @ObservedObject var viewModel: TrainingViewModel

    @State private var goalName = ""
    @State private var goalRaceDate = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    @State private var goalDistanceText = ""
    @State private var goalClimbText = ""

    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var showingPlanExplainer = false
    @State private var expandedSessionKind: SessionKind?

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
                        thisWeekSection(progress, hrMax: plan.hrMax)
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
            if plan.longestPlannedRunKm < goal.distanceKm {
                Text(honestLimitText(plan: plan, goal: goal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            planExplainerDisclosure(plan: plan)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// La sortie la plus longue du plan comparée à la distance de course :
    /// le chiffre le plus déterminant de l'écran, jusque-là passé sous silence.
    private func honestLimitText(plan: TrainingPlan, goal: RaceGoal) -> String {
        let pct = Int((plan.longestPlannedRunKm / goal.distanceKm * 100).rounded())
        return "Plus longue sortie du plan : "
            + plan.longestPlannedRunKm.formatted(.number.precision(.fractionLength(1)))
            + " km, soit \(pct) % des "
            + goal.distanceKm.formatted(.number.precision(.fractionLength(1)))
            + " km de la course."
    }

    /// « Comment ce plan est construit » — repliée par défaut, pour que la
    /// carte reste aussi compacte qu'aujourd'hui au repos.
    @ViewBuilder
    private func planExplainerDisclosure(plan: TrainingPlan) -> some View {
        Button {
            withAnimation(.snappy) { showingPlanExplainer.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("Comment ce plan est construit").font(.caption)
                Image(systemName: showingPlanExplainer ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        if showingPlanExplainer {
            Text(planExplainerText(plan: plan))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planExplainerText(plan: TrainingPlan) -> String {
        // Plan de maintien (spec §5.2) : aucune semaine ne monte, donc la
        // phrase d'arc décrirait quelque chose qui n'existe pas, et
        // « base mesurée / +N % » n'a pas de sens sans rampe.
        if plan.isMaintenance {
            return "Trop tard pour progresser : ce plan entretient votre forme jusqu'à la course sans "
                + "chercher à l'augmenter."
        }

        let rampPercent = Int(((plan.rampFactor - 1) * 100).rounded())
        var text = planArcText(rampWeeks: plan.rampWeekCount, taperWeeks: plan.taperWeekCount)
            + " Le plus gros volume tombe deux semaines avant la course, pas la veille : vous ne "
            + "progressez pas pendant l'effort mais pendant que vous récupérez de l'effort.\n\n"
            + "Base mesurée : "
            + plan.anchorBaseKm.formatted(.number.precision(.fractionLength(1)))
            + " km/semaine. Chaque semaine ajoute au plus \(rampPercent) % à la précédente — le "
            + "garde-fou principal contre la blessure : le corps s'adapte en semaines, les tendons et "
            + "les os en mois."
        if plan.rampFactor == TrainingPlanner.comebackRampFactor {
            text += " Ce rythme un peu plus soutenu est celui d'une reprise : votre base est sous la "
                + "distance de course."
        }
        return text
    }

    /// « Trois semaines qui montent, deux qui redescendent. » — dérivée du
    /// plan plutôt que figée : la longueur de l'arc de montée dépend de la
    /// distance à la course (spec `peakIndex = mondays.count - 3`), un plan
    /// à cinq semaines et un plan à onze semaines n'ont pas le même compte.
    private func planArcText(rampWeeks: Int, taperWeeks: Int) -> String {
        let up = rampWeeks == 1
            ? "Une semaine qui monte"
            : "\(TrainingView.capitalizedFirst(TrainingView.frenchWeekCount(rampWeeks))) semaines qui montent"
        let down = taperWeeks == 1
            ? "une qui redescend"
            : "\(TrainingView.frenchWeekCount(taperWeeks)) qui redescendent"
        return "\(up), \(down)."
    }

    /// Nombre d'une semaine en toutes lettres, accordé au féminin (accorde
    /// avec « semaine(s) »). Retombe sur le chiffre au-delà de la table :
    /// un plan ne dépasse jamais quelques dizaines de semaines, mais mieux
    /// vaut un chiffre correct qu'un mot halluciné sur un cas extrême.
    private static func frenchWeekCount(_ n: Int) -> String {
        let words = ["zéro", "une", "deux", "trois", "quatre", "cinq", "six", "sept",
                     "huit", "neuf", "dix", "onze", "douze", "treize", "quatorze",
                     "quinze", "seize", "dix-sept", "dix-huit", "dix-neuf", "vingt"]
        return n >= 0 && n < words.count ? words[n] : "\(n)"
    }

    private static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
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

    private func thisWeekSection(_ progress: WeekProgress, hrMax: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cette semaine").font(.title2.bold())
            VStack(spacing: 8) {
                ForEach(Array(progress.matched.enumerated()), id: \.offset) { _, matched in
                    matchedSessionRow(matched, hrMax: hrMax)
                }
                ForEach(Array(progress.offPlan.enumerated()), id: \.offset) { _, workout in
                    offPlanRow(workout)
                }
            }
        }
    }

    @ViewBuilder
    private func matchedSessionRow(_ matched: MatchedSession, hrMax: Double) -> some View {
        let isExpanded = expandedSessionKind == matched.session.kind
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionLabel(matched.session.kind)).font(.callout.weight(.semibold))
                    Text(matched.session.note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(targetText(matched.session)).font(.callout.monospacedDigit())
                    Text(bpmRangeText(matched.session.hrRange, hrMax: hrMax, kind: matched.session.kind))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                doneBadge(isDone: matched.isDone)
            }
            Button {
                withAnimation(.snappy) {
                    expandedSessionKind = isExpanded ? nil : matched.session.kind
                }
            } label: {
                Label(isExpanded ? "Masquer" : "Pourquoi ?",
                     systemImage: isExpanded ? "chevron.up" : "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text(matched.session.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    private func bpmRangeText(_ range: ClosedRange<Double>, hrMax: Double, kind: SessionKind) -> String {
        let low = Int(range.lowerBound.rounded())
        let high = Int(range.upperBound.rounded())
        let pctLow = Int((range.lowerBound / hrMax * 100).rounded())
        let pctHigh = Int((range.upperBound / hrMax * 100).rounded())
        return "\(low)–\(high) bpm · \(pctLow)–\(pctHigh) % FC max · \(intensityLabel(kind))"
    }

    private func intensityLabel(_ kind: SessionKind) -> String {
        switch kind {
        case .longRun: return "endurance"
        case .hills: return "intensité"
        case .baseEndurance, .optionalEasy: return "récupération active"
        case .legOpener: return "réveil"
        }
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
                            // L'alerte d'effondrement tient sur deux phrases —
                            // deux cibles chiffrées et la sortie de secours —
                            // là où les autres en font une : elle doit
                            // s'enrouler, jamais se tronquer.
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
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
                            upcomingWeekRow(week, rampFactor: plan.rampFactor)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func upcomingWeekRow(_ week: PlannedWeek, rampFactor: Double) -> some View {
        let longRun = week.sessions.first { $0.kind == .longRun }
        let hills = week.sessions.first { $0.kind == .hills }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(week.monday.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                    .font(.callout.weight(.semibold))
                Text(roleLabel(week.role)).font(.caption).foregroundStyle(.secondary)
                Text(weekRoleCaption(week.role, rampFactor: rampFactor))
                    .font(.caption2).foregroundStyle(.secondary)
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

    private func weekRoleCaption(_ role: WeekRole, rampFactor: Double) -> String {
        switch role {
        case .currentWeekClosing:
            return "Trop entamée pour recevoir des cibles — la montée démarre lundi."
        case .build:
            let ramp = Int(((rampFactor - 1) * 100).rounded())
            return "Montée en charge — au plus +\(ramp) % sur la semaine précédente."
        case .peak:
            return "Le plus gros volume du plan, deux semaines avant la course."
        case .taper:
            return "On allège pour arriver frais. Le travail est déjà fait."
        case .raceWeek:
            return "Volume minimal, jambes réveillées."
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
