import SwiftUI

/// Onglet « Conseils » : forme, conseil du jour, tendance VO2max — calculés
/// localement (`CompanionAdvisorViewModel`), jamais depuis le Mac. Pas de
/// poids sur cet écran (spec §2). Style visuel propre au Companion
/// (padding/rayon existants, cf. `CompanionRootView.syncCard`), pas le
/// gabarit du Mac (`WellnessViews.swift`) — ce fichier n'est pas dans les
/// sources de cette cible.
struct CompanionAdvisorView: View {
    @ObservedObject var viewModel: CompanionAdvisorViewModel
    let lastSyncDate: Date?
    @ObservedObject var trendsViewModel: TrendsViewModel
    @ObservedObject var correlationsViewModel: CorrelationsViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            Group {
                if viewModel.storeUnavailable {
                    storeUnavailableCard
                } else if !viewModel.hasLoaded {
                    // Premier calcul en cours : les lectures GRDB tournent hors
                    // du `MainActor` et peuvent durer si l'import HealthKit
                    // tient le verrou. Les rafraîchissements suivants gardent
                    // les cartes déjà affichées, il n'y a que ce premier écran
                    // à remplir.
                    loadingCard
                } else if viewModel.readiness == nil && viewModel.dailyAdvice == nil
                    && viewModel.vo2Trend == nil && viewModel.today == nil {
                    notEnoughDataCard
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let readiness = viewModel.readiness {
                            readinessCard(readiness)
                        }
                        if let today = viewModel.today {
                            todayCard(today)
                        }
                        if let advice = viewModel.dailyAdvice {
                            dailyAdviceCard(advice)
                        }
                        if let trend = viewModel.vo2Trend {
                            vo2Card(trend, alert: viewModel.vo2MaxAlert)
                        }
                        if !viewModel.insights.isEmpty {
                            insightsCard
                        }
                        trendsLink
                        correlationsLink
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { await viewModel.refresh() } }
        .onChange(of: lastSyncDate) { _, _ in Task { await viewModel.refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await viewModel.refresh() } }
        }
        .refreshable { await viewModel.refresh() }
    }

    private func readinessCard(_ readiness: ReadinessScore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Forme", systemImage: "heart.fill")
                .font(.headline)
            Text("\(Int(readiness.value.rounded())) / 100")
                .font(.title2.bold())
                .monospacedDigit()
                // « 62 / 100 » se lit « 62 barre oblique 100 » sans ceci.
                .accessibilityLabel("\(Int(readiness.value.rounded())) sur 100")
            Text(readiness.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func todayCard(_ summary: PeriodSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Aujourd'hui", systemImage: "sun.max.fill")
                .font(.headline)
            Text("\(Int(summary.steps.rounded())) pas · \(summary.distanceKm.formatted(.number.precision(.fractionLength(1)))) km")
                .font(.callout)
            Text("\(Int(summary.activeEnergyKcal.rounded())) kcal actives · \(Int(summary.exerciseMinutes.rounded())) min d'exercice")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let week = viewModel.thisWeek {
                Text("Cette semaine : \(Int(week.steps.rounded())) pas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Observations", systemImage: "lightbulb.fill")
                .font(.headline)
            ForEach(Array(viewModel.insights.enumerated()), id: \.offset) { _, insight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: insight.systemImage)
                        .foregroundStyle(Self.tint(for: insight.sentiment))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(.callout.weight(.semibold))
                        Text(insight.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func tint(for sentiment: Insight.Sentiment) -> Color {
        switch sentiment {
        case .positive: return .green
        case .neutral: return .secondary
        case .warning: return .orange
        }
    }

    private func dailyAdviceCard(_ advice: DailyAdvice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(adviceTitle(advice.tier), systemImage: adviceSystemImage(advice.tier))
                .font(.headline)
                .foregroundStyle(adviceTint(advice.tier))
            Text(advice.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func adviceTint(_ tier: AdviceTier) -> Color {
        switch tier {
        case .repos: return .orange
        case .prudence: return .blue
        case .opportunite: return .green
        }
    }

    private func adviceSystemImage(_ tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "exclamationmark.triangle.fill"
        case .prudence: return "info.circle.fill"
        case .opportunite: return "checkmark.circle.fill"
        }
    }

    private func adviceTitle(_ tier: AdviceTier) -> String {
        switch tier {
        case .repos: return "Repos conseillé"
        case .prudence: return "Prudence"
        case .opportunite: return "Opportunité"
        }
    }

    private func vo2Card(_ trend: VO2MaxTrend, alert: LoadAlert?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("VO2max", systemImage: "lungs.fill")
                .font(.headline)
            Text(vo2VerdictLabel(trend.verdict))
                .font(.callout.weight(.semibold))
            Text("Moyenne 30 jours : \(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg (\(trend.delta >= 0 ? "+" : "")\(trend.delta.formatted(.number.precision(.fractionLength(1)))) vs. les 90 jours précédents)")
                .font(.caption)
                .foregroundStyle(.secondary)
                // « mL/min·kg » se lit caractère par caractère sans ceci.
                .accessibilityLabel(vo2DetailAccessibilityLabel(trend))
            if let alert {
                Label(alert.message,
                     systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func vo2DetailAccessibilityLabel(_ trend: VO2MaxTrend) -> String {
        let average = trend.recentAverage.formatted(.number.precision(.fractionLength(1)))
        let delta = abs(trend.delta).formatted(.number.precision(.fractionLength(1)))
        let direction = trend.delta >= 0 ? "en hausse de" : "en baisse de"
        return "moyenne sur 30 jours, \(average) millilitres par minute et par kilo, \(direction) \(delta) par rapport aux 90 jours précédents"
    }

    private func vo2VerdictLabel(_ verdict: VO2MaxVerdict) -> String {
        switch verdict {
        case .rising: return "VO2max : en hausse"
        case .stable: return "VO2max : stable"
        case .declining: return "VO2max : en baisse"
        }
    }

    private var storeUnavailableCard: some View {
        VStack(spacing: 8) {
            Label("Base de données locale indisponible", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Redémarrez l'application. Si le problème persiste, vérifiez l'espace disque disponible sur l'iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var loadingCard: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Calcul en cours…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var notEnoughDataCard: some View {
        VStack(spacing: 8) {
            Label("Pas encore assez de données", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text("Vos données Santé s'accumulent sur l'iPhone au fil des jours. Revenez bientôt — cet écran n'attend rien du Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    /// Même gabarit que « Voir mes séances » sous Entraînement (SP3) :
    /// Tendances est un sous-écran de l'Accueil, pas un sixième onglet — au
    /// delà de cinq, iOS empile le reste derrière un menu « Plus ».
    private var trendsLink: some View {
        NavigationLink {
            CompanionTrendsView(viewModel: trendsViewModel)
                .navigationTitle("Tendances")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("Voir mes tendances", systemImage: "chart.xyaxis.line")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var correlationsLink: some View {
        NavigationLink {
            CompanionCorrelationsView(viewModel: correlationsViewModel)
                .navigationTitle("Corrélations")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label("Voir mes corrélations", systemImage: "chart.dots.scatter")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

}
