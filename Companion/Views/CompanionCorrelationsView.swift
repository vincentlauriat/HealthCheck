import SwiftUI
import Charts

/// Sous-écran « Corrélations » de l'Accueil. `CorrelationsViewModel` tourne
/// sur 180 jours fixes, exactement la fenêtre lue dans HealthKit : rien à
/// borner ici, contrairement aux Tendances.
struct CompanionCorrelationsView: View {
    @ObservedObject var viewModel: CorrelationsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Sur tes \(CorrelationsViewModel.windowDays) derniers jours. La corrélation mesure un lien statistique, pas une cause : un r fort peut venir d'un facteur commun (saison, routine, maladie).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(viewModel.cards, id: \.question) { card in
                    correlationCard(card)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private func correlationCard(_ card: CorrelationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.question)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let result = card.result {
                    Text("r = \(result.r.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2))))")
                        .font(.callout.bold())
                        .monospacedDigit()
                        .foregroundStyle(strengthColor(result.r))
                }
            }

            Text(card.reading)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result = card.result {
                Chart(result.points, id: \.day) { point in
                    PointMark(x: .value(card.xLabel, point.x), y: .value(card.yLabel, point.y))
                        .foregroundStyle(strengthColor(result.r).opacity(0.55))
                        .symbolSize(24)
                }
                .chartXAxisLabel(card.xLabel)
                .chartYAxisLabel(card.yLabel)
                .chartXScale(domain: .automatic(includesZero: false))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func strengthColor(_ r: Double) -> Color {
        switch abs(r) {
        case 0.6...: return .purple
        case 0.4..<0.6: return .blue
        case 0.2..<0.4: return .teal
        default: return .gray
        }
    }
}
