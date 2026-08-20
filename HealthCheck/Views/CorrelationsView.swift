import SwiftUI
import Charts

struct CorrelationsView: View {
    @ObservedObject var viewModel: CorrelationsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sur tes \(CorrelationsViewModel.windowDays) derniers jours. La corrélation mesure un lien statistique, pas une cause : un r fort peut venir d'un facteur commun (saison, routine, maladie).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)

                ForEach(viewModel.cards, id: \.question) { card in
                    correlationCard(card)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { try? viewModel.load() }
    }

    @ViewBuilder
    private func correlationCard(_ card: CorrelationCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.question).font(.headline)
                Spacer()
                if let result = card.result {
                    Text("r = \(result.r.formatted(.number.sign(strategy: .always()).precision(.fractionLength(2))))")
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(strengthColor(result.r))
                }
            }

            Text(card.reading)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let result = card.result {
                Chart(result.points, id: \.day) { point in
                    PointMark(x: .value(card.xLabel, point.x), y: .value(card.yLabel, point.y))
                        .foregroundStyle(strengthColor(result.r).opacity(0.55))
                        .symbolSize(30)
                }
                .chartXAxisLabel(card.xLabel)
                .chartYAxisLabel(card.yLabel)
                .chartXScale(domain: .automatic(includesZero: false))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 170)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: 640)
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
