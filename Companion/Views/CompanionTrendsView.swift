import SwiftUI
import Charts

/// Sous-écran « Tendances » de l'Accueil : quatre courbes sur une période
/// choisie, bornée à ce que l'iPhone possède réellement.
struct CompanionTrendsView: View {
    @ObservedObject var viewModel: TrendsViewModel
    @State private var period: TrendPeriod = .threeMonths

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Picker("Période", selection: $period) {
                    ForEach(TrendPeriod.companionCases, id: \.self) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                historyDepthNote

                card(.restingHeartRate, points: viewModel.restingHeartRate, precision: 0)
                card(.weight, points: viewModel.weight, precision: 1)
                card(.vo2Max, points: viewModel.vo2Max, precision: 1)
                card(.sleep, points: viewModel.sleepHours, precision: 1)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load(period: period) } }
        .onChange(of: period) { _, newPeriod in try? viewModel.load(period: newPeriod) }
        .refreshable { try? viewModel.load(period: period) }
    }

    /// Affichée seulement quand les données commencent après la période
    /// demandée : sinon elle n'apprendrait rien. La tolérance d'un jour évite
    /// que la mention s'affiche pour l'écart d'arrondi entre le début de
    /// période et le premier échantillon du jour.
    @ViewBuilder
    private var historyDepthNote: some View {
        if let earliest = viewModel.earliestMeasurement,
           earliest > period.startDate(now: Date(), calendar: .current).addingTimeInterval(86_400) {
            Label("Mesures disponibles depuis le \(earliest.formatted(.dateTime.day().month(.wide).year()))",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
    }

    private func card(_ style: MetricStyle, points: [TrendPoint], precision: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(style.title, systemImage: style.systemImage)
                    .font(.headline)
                    .foregroundStyle(style.tint)
                Spacer()
                if let latest = points.last {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(latest.value.formatted(.number.precision(.fractionLength(0...precision))))
                            .font(.title3.bold())
                            .monospacedDigit()
                        Text(style.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if points.isEmpty {
                Text("Aucune donnée sur cette période.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                chart(style: style, points: points)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    /// L'aire dégradée du Mac est volontairement omise : à cette largeur, une
    /// courbe et sa moyenne mobile suffisent, l'aire n'ajoutait que du bruit.
    private func chart(style: MetricStyle, points: [TrendPoint]) -> some View {
        let smoothed = TrendsViewModel.movingAverage(points)
        return Chart {
            ForEach(points, id: \.date) { point in
                LineMark(x: .value("Date", point.date), y: .value(style.title, point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(style.tint)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(smoothed, id: \.date) { point in
                LineMark(x: .value("Date", point.date),
                         y: .value("Moyenne 7 j", point.value),
                         series: .value("Série", "Moyenne 7 j"))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 170)
    }
}
