import SwiftUI
import Charts

struct ActivityView: View {
    @ObservedObject var viewModel: ActivityViewModel

    private static let zoneNames = ["Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"]
    private static let zoneColors: [Color] = [.blue, .teal, .yellow, .orange, .red]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                todayCard
                if !viewModel.history.isEmpty {
                    historyChart
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { try? viewModel.load() }
    }

    @ViewBuilder
    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Effort du jour").font(.title2.bold())
            if let maxHR = viewModel.maxHeartRate {
                Text("Zones basées sur votre FC max observée : \(Int(maxHR)) bpm")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 8) {
                    ScoreRingView(score: viewModel.today?.score ?? 0)
                    Text(StrainEngine.label(for: viewModel.today?.score ?? 0))
                        .font(.subheadline.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 8) {
                    let zones = viewModel.today?.zoneMinutes ?? [0, 0, 0, 0, 0]
                    let maxMinutes = max(zones.max() ?? 1, 1)
                    ForEach(Array(zones.enumerated().reversed()), id: \.offset) { index, minutes in
                        HStack(spacing: 10) {
                            Text(Self.zoneNames[index])
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Self.zoneColors[index])
                                .frame(width: 52, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary)
                                    Capsule()
                                        .fill(Self.zoneColors[index])
                                        .frame(width: max(geo.size.width * minutes / maxMinutes, minutes > 0 ? 6 : 0))
                                }
                            }
                            .frame(height: 8)
                            Text("\(Int(minutes.rounded())) min")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    if let energy = viewModel.todayActiveEnergy, let exercise = viewModel.todayExerciseMinutes {
                        Text("\(Int(energy.rounded())) kcal actives · \(Int(exercise.rounded())) min d'exercice")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
    }

    private var historyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("14 derniers jours").font(.title2.bold())
            Chart(viewModel.history, id: \.day) { day in
                BarMark(x: .value("Jour", day.day, unit: .day), y: .value("Effort", day.score))
                    .foregroundStyle(severityColor(day.score))
                    .cornerRadius(3)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 180)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
    }

    private func severityColor(_ score: Double) -> Color {
        switch score {
        case 70...: return .red
        case 40..<70: return .orange
        default: return .green
        }
    }
}
