import SwiftUI

/// Onglet « Entraînement ». Deux sources, chacune à sa place : la charge et
/// le VO2max sont calculés localement par `TrainingViewModel` sur la base de
/// l'iPhone, le plan vient du cache alimenté par le Mac
/// (`CompanionViewModel`). Les objectifs de course se créent sur le Mac, donc
/// `race_goal` est vide ici — sans objectif, le plan local et la progression
/// n'ont pas de sens, mais le suivi de charge reste pertinent : c'est le mode
/// « entre deux courses », et c'est ce que l'écran affiche.
///
/// Le plan en cache vivait dans l'écran Synchro jusqu'au SP3. Il a déménagé
/// ici : l'appairage est une configuration, le plan est un contenu quotidien.
struct CompanionTrainingView: View {
    @ObservedObject var viewModel: TrainingViewModel
    @ObservedObject var planViewModel: CompanionViewModel
    @ObservedObject var workoutsViewModel: WorkoutsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let assessment = viewModel.assessment {
                    loadCard(assessment)
                }
                if let status = viewModel.vo2MaxStatus, status.trend != nil || status.alert != nil {
                    vo2Card(status)
                }
                if viewModel.assessment == nil && viewModel.vo2MaxStatus?.trend == nil {
                    ContentUnavailableView(
                        "Pas encore de séance enregistrée",
                        systemImage: "figure.run",
                        description: Text("Vos sorties apparaîtront ici dès qu'elles seront enregistrées dans Santé.")
                    )
                    .padding(.top, 40)
                }

                NavigationLink {
                    CompanionWorkoutsView(viewModel: workoutsViewModel)
                        .navigationTitle("Séances")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Voir mes séances", systemImage: "list.bullet")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                planSection
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    // MARK: - Charge et VO2max (calcul local)

    private func loadCard(_ assessment: LoadAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Charge d'entraînement", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
            LabeledContent("7 derniers jours",
                           value: "\(assessment.acuteKm.formatted(.number.precision(.fractionLength(1)))) km")
            LabeledContent("Moyenne hebdomadaire",
                           value: "\(assessment.chronicWeeklyKm.formatted(.number.precision(.fractionLength(1)))) km")
            if let acwr = assessment.acwr {
                LabeledContent("Rapport aigu/chronique",
                               value: acwr.formatted(.number.precision(.fractionLength(2))))
            }
            ForEach(Array(assessment.alerts.enumerated()), id: \.offset) { _, alert in
                alertLabel(alert)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func vo2Card(_ status: VO2MaxStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("VO2max", systemImage: "lungs.fill")
                .font(.headline)
            if let trend = status.trend {
                Text("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel("VO2max \(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) millilitres par minute et par kilo")
            }
            if let alert = status.alert {
                alertLabel(alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func alertLabel(_ alert: LoadAlert) -> some View {
        Label(alert.message,
              systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.callout)
            .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    // MARK: - Plan d'entraînement (cache alimenté par le Mac)

    /// Le plan n'a de sens qu'appairé : c'est le Mac qui le calcule. Non
    /// appairé, l'onglet reste utile — la charge et le VO2max, eux, ne
    /// dépendent de rien d'extérieur.
    @ViewBuilder
    private var planSection: some View {
        if planViewModel.isPaired {
            trainingPlanContent
        }
    }

    private var currentWeek: TrainingWeekSummary? {
        guard let plan = planViewModel.trainingPlan else { return nil }
        let currentMonday = monday(of: Date())
        return plan.weeks.first { Calendar.current.isDate($0.monday, inSameDayAs: currentMonday) }
            ?? plan.weeks.first { $0.monday >= currentMonday }
            ?? plan.weeks.last
    }

    private var visibleWeeks: [TrainingWeekSummary] {
        guard let plan = planViewModel.trainingPlan else { return [] }
        let currentMonday = monday(of: Date())
        return plan.weeks
            .filter { $0.monday >= currentMonday }
            .prefix(12)
            .map { $0 }
    }

    private var trainingPlanContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plan d'entraînement")
                    .font(.title3.weight(.semibold))
                Spacer()
                if planViewModel.isLoadingTrainingPlan {
                    ProgressView()
                } else {
                    Button {
                        Task { await planViewModel.refreshTrainingPlan() }
                    } label: {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Actualiser le plan d'entraînement")
                }
            }

            if let plan = planViewModel.trainingPlan {
                if let goal = plan.goal {
                    goalSummary(goal)
                }

                if let message = plan.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }

                if let week = currentWeek {
                    weekCard(week, title: "Cette semaine", expanded: true)
                }

                let otherWeeks = visibleWeeks.filter { week in
                    guard let currentWeek else { return true }
                    return !Calendar.current.isDate(week.monday, inSameDayAs: currentWeek.monday)
                }

                if !otherWeeks.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text("Prochaines semaines")
                            .font(.headline)
                        ForEach(otherWeeks, id: \.monday) { week in
                            weekCard(week, title: nil, expanded: false)
                        }
                    }
                }
            } else {
                emptyPlanCard
            }
        }
    }

    private var emptyPlanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aucun plan local", systemImage: "calendar.badge.exclamationmark")
                .font(.headline)
            Text("Actualisez le plan quand le Mac est ouvert. Le dernier plan reçu restera ensuite disponible hors ligne.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await planViewModel.refreshTrainingPlan() }
            } label: {
                Label("Actualiser le plan", systemImage: "arrow.clockwise")
            }
            .disabled(planViewModel.isLoadingTrainingPlan)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func goalSummary(_ goal: TrainingGoalSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(goal.name)
                .font(.headline)
            Text(goal.raceDate.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(goal.distanceKm.formatted(.number.precision(.fractionLength(1))) + " km", systemImage: "figure.run")
                Label("D+ \(Int(goal.elevationGainM.rounded())) m", systemImage: "mountain.2.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func weekCard(_ week: TrainingWeekSummary, title: String?, expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? week.monday.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(week.role)
                    Text(week.targetKm.formatted(.number.precision(.fractionLength(1))) + " km")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if expanded {
                sessionList(week)
            } else {
                DisclosureGroup("\(week.sessions.count) séance(s)") {
                    sessionList(week)
                }
                .font(.callout)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sessionList(_ week: TrainingWeekSummary) -> some View {
        VStack(spacing: 0) {
            if week.sessions.isEmpty {
                Text("Aucune séance cible cette semaine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(week.sessions.enumerated()), id: \.offset) { index, session in
                    let id = planViewModel.trainingSessionID(week: week, session: session, index: index)
                    sessionRow(session, id: id)
                    if index < week.sessions.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: TrainingSessionSummary, id: String) -> some View {
        let isCompleted = planViewModel.isTrainingSessionCompleted(id: id)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                planViewModel.toggleTrainingSessionCompleted(id: id)
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompleted ? .green : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Marquer comme non fait" : "Marquer comme fait")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.kind)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(session.targetText)
                        .font(.callout.monospacedDigit())
                }
                Text(session.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.rationale.isEmpty {
                    Text(session.rationale)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .opacity(isCompleted ? 0.58 : 1)
        }
        .padding(.vertical, 8)
    }

    private func monday(of date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)
        let offset = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }
}
