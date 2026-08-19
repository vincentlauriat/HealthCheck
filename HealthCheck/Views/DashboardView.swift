import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            periodSection(title: "Aujourd'hui", summary: viewModel.today)
            periodSection(title: "Cette semaine", summary: viewModel.thisWeek)
        }
        .padding()
        .task {
            try? viewModel.loadToday()
            try? viewModel.loadThisWeek()
        }
    }

    @ViewBuilder
    private func periodSection(title: String, summary: PeriodSummary?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold())

            if let summary {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow { Text("Pas"); Text(summary.steps, format: .number) }
                    GridRow { Text("Distance"); Text(summary.distanceKm, format: .number) + Text(" km") }
                    GridRow { Text("Calories actives"); Text(summary.activeEnergyKcal, format: .number) + Text(" kcal") }
                    GridRow { Text("Minutes d'exercice"); Text(summary.exerciseMinutes, format: .number) }
                    GridRow {
                        Text("FC repos")
                        if let hr = summary.restingHeartRate {
                            Text(hr, format: .number) + Text(" bpm")
                        } else {
                            Text("—")
                        }
                    }
                }
            } else {
                Text("Aucune donnée importée pour l'instant.").foregroundStyle(.secondary)
            }
        }
    }
}
