import SwiftUI
import Charts

struct TrendsView: View {
    @ObservedObject var viewModel: TrendsViewModel
    @State private var period: TrendPeriod = .sixMonths

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Période", selection: $period) {
                    Text("3 mois").tag(TrendPeriod.threeMonths)
                    Text("6 mois").tag(TrendPeriod.sixMonths)
                    Text("1 an").tag(TrendPeriod.oneYear)
                    Text("Tout").tag(TrendPeriod.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TrendChartCard(style: .restingHeartRate, points: viewModel.restingHeartRate, valuePrecision: 0)
                TrendChartCard(style: .weight, points: viewModel.weight, valuePrecision: 1)
                TrendChartCard(style: .vo2Max, points: viewModel.vo2Max, valuePrecision: 1)
                TrendChartCard(style: .sleep, points: viewModel.sleepHours, valuePrecision: 1)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { try? viewModel.load(period: period) }
        .onChange(of: period) { _, newPeriod in
            try? viewModel.load(period: newPeriod)
        }
    }
}

/// Carte de tendance : en-tête (icône, titre, dernière valeur), graphique en
/// aire dégradée + courbe lissée, et moyenne mobile 7 points en pointillés
/// quand la série est assez longue pour qu'un lissage ait du sens.
struct TrendChartCard: View {
    let style: MetricStyle
    let points: [TrendPoint]
    let valuePrecision: Int

    private var smoothed: [TrendPoint] { TrendsViewModel.movingAverage(points) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(style.title, systemImage: style.systemImage)
                    .font(.headline)
                    .foregroundStyle(style.tint)
                Spacer()
                if let latest = points.last {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(latest.value.formatted(.number.precision(.fractionLength(0...valuePrecision))))
                            .font(.title3.bold())
                            .monospacedDigit()
                        Text(style.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("Dernière valeur : \(latest.date.formatted(date: .abbreviated, time: .omitted))")
                }
            }

            if points.isEmpty {
                ContentUnavailableView {
                    Label("Aucune donnée sur cette période", systemImage: style.systemImage)
                } description: {
                    Text("Importez un export plus récent ou élargissez la période.")
                }
                .frame(height: 120)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value(style.title, point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [style.tint.opacity(0.3), style.tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(style.title, point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(style.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }

                    ForEach(smoothed, id: \.date) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Moyenne 7 j", point.value),
                            series: .value("Série", "Moyenne 7 j")
                        )
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}
