import SwiftUI
import Charts

struct TrendsView: View {
    @ObservedObject var viewModel: TrendsViewModel
    @State private var period: TrendPeriod = .sixMonths

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Période", selection: $period) {
                    Text("3 mois").tag(TrendPeriod.threeMonths)
                    Text("6 mois").tag(TrendPeriod.sixMonths)
                    Text("1 an").tag(TrendPeriod.oneYear)
                    Text("Tout").tag(TrendPeriod.all)
                }
                .pickerStyle(.segmented)

                chartSection(title: "Fréquence cardiaque au repos", unit: "bpm", points: viewModel.restingHeartRate)
                chartSection(title: "Poids", unit: "kg", points: viewModel.weight)
                chartSection(title: "VO2 max", unit: "ml/kg/min", points: viewModel.vo2Max)
                chartSection(title: "Sommeil", unit: "h/nuit", points: viewModel.sleepHours)
            }
            .padding()
        }
        .task { try? viewModel.load(period: period) }
        .onChange(of: period) { _, newPeriod in
            try? viewModel.load(period: newPeriod)
        }
    }

    @ViewBuilder
    private func chartSection(title: String, unit: String, points: [TrendPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) (\(unit))").font(.headline)
            if points.isEmpty {
                Text("Aucune donnée sur cette période.").foregroundStyle(.secondary)
            } else {
                Chart(points, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value(title, point.value))
                }
                .frame(height: 160)
            }
        }
    }
}
