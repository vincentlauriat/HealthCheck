import SwiftUI

/// L'unique écran : appairage ou synchro selon l'état.
struct CompanionRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @State private var code = ""
    @State private var showUnpairConfirmation = false

    private var currentWeek: TrainingWeekSummary? {
        guard let plan = viewModel.trainingPlan else { return nil }
        let currentMonday = monday(of: Date())
        return plan.weeks.first { Calendar.current.isDate($0.monday, inSameDayAs: currentMonday) }
            ?? plan.weeks.first { $0.monday >= currentMonday }
            ?? plan.weeks.last
    }

    private var visibleWeeks: [TrainingWeekSummary] {
        guard let plan = viewModel.trainingPlan else { return [] }
        let currentMonday = monday(of: Date())
        return plan.weeks
            .filter { $0.monday >= currentMonday }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isPaired {
                    pairedContent
                } else {
                    pairingContent
                }
            }
            .navigationTitle("HealthCheck")
            .confirmationDialog(
                "Oublier ce Mac ?",
                isPresented: $showUnpairConfirmation,
                titleVisibility: .visible
            ) {
                Button("Oublier", role: .destructive) {
                    viewModel.unpair()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("L'appairage sera supprimé et la synchronisation s'arrêtera. Vous devrez saisir un nouveau code depuis votre Mac pour la reprendre.")
            }
        }
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                syncCard

                if let error = viewModel.errorMessage {
                    warningCard(error)
                }

                trainingPlanContent

                Button("Oublier ce Mac", role: .destructive) {
                    showUnpairConfirmation = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable {
            await viewModel.refreshTrainingPlan()
        }
    }

    private var pairingContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Appairage Mac", systemImage: "macbook.and.iphone")
                        .font(.title3.weight(.semibold))
                    Text("Sur votre Mac : HealthCheck > Données > carte iPhone > Appairer, puis saisissez le code ici.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Code à 6 chiffres", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await viewModel.submitPairingCode(code) }
                    } label: {
                        Label("Appairer", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(code.count != 6)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 8))

                if let error = viewModel.errorMessage {
                    warningCard(error)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Appairé", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                if viewModel.isSyncing {
                    ProgressView()
                }
            }

            if let last = viewModel.lastSyncDate {
                LabeledContent("Dernière synchro", value: last.formatted(.relative(presentation: .named)))
                    .font(.callout)
            }

            if let summary = viewModel.lastReportSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.syncNow() }
                } label: {
                    Label(viewModel.isSyncing ? "Synchronisation" : "Synchroniser", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isSyncing)
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await viewModel.refreshTrainingPlan() }
                } label: {
                    Label("Plan", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingTrainingPlan)
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var trainingPlanContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plan d'entraînement")
                    .font(.title3.weight(.semibold))
                Spacer()
                if viewModel.isLoadingTrainingPlan {
                    ProgressView()
                }
            }

            if let plan = viewModel.trainingPlan {
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
                Task { await viewModel.refreshTrainingPlan() }
            } label: {
                Label("Actualiser le plan", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingTrainingPlan)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                    let id = viewModel.trainingSessionID(week: week, session: session, index: index)
                    sessionRow(session, id: id)
                    if index < week.sessions.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: TrainingSessionSummary, id: String) -> some View {
        let isCompleted = viewModel.isTrainingSessionCompleted(id: id)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                viewModel.toggleTrainingSessionCompleted(id: id)
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
