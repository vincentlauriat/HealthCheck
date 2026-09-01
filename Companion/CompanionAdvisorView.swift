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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            Group {
                if viewModel.storeUnavailable {
                    storeUnavailableCard
                } else if viewModel.hasLoaded && viewModel.readiness == nil
                    && viewModel.dailyAdvice == nil && viewModel.vo2Trend == nil {
                    notEnoughDataCard
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let readiness = viewModel.readiness {
                            readinessCard(readiness)
                        }
                        if let advice = viewModel.dailyAdvice {
                            dailyAdviceCard(advice)
                        }
                        if let trend = viewModel.vo2Trend {
                            vo2Card(trend, alert: viewModel.vo2MaxAlert)
                        }
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
            Text("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg (\(trend.delta >= 0 ? "+" : "")\(trend.delta.formatted(.number.precision(.fractionLength(1)))) vs. les 90 jours précédents)")
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
        return "\(average) millilitres par minute et par kilo, \(direction) \(delta) par rapport aux 90 jours précédents"
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

    private var notEnoughDataCard: some View {
        VStack(spacing: 8) {
            Label("Pas encore assez de données", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Text("Synchronisez, ou revenez dans quelques jours.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
