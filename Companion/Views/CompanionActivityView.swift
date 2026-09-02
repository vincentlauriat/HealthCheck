import SwiftUI
import Charts

/// Onglet « Activité » : effort du jour par zone de fréquence cardiaque et
/// historique sur 14 jours, calculés localement par `ActivityViewModel`
/// (partagé avec le Mac). Gabarit visuel du Companion, pas celui du Mac.
struct CompanionActivityView: View {
    @ObservedObject var viewModel: ActivityViewModel

    private static let zoneNames = ["Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"]
    private static let zoneColors: [Color] = [.blue, .teal, .yellow, .orange, .red]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if viewModel.today == nil && viewModel.history.isEmpty {
                    ContentUnavailableView(
                        "Pas encore d'effort mesuré",
                        systemImage: "figure.walk",
                        description: Text("Portez votre montre pendant l'effort : les zones se calculent à partir de la fréquence cardiaque.")
                    )
                    .padding(.top, 40)
                } else {
                    todayCard
                    if !viewModel.history.isEmpty {
                        historyCard
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Effort du jour", systemImage: "flame.fill")
                .font(.headline)
            if let maxHR = viewModel.maxHeartRate {
                Text("Zones basées sur votre FC max observée : \(Int(maxHR)) bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 6) {
                    CompanionScoreRingView(score: viewModel.today?.score ?? 0)
                    Text(StrainEngine.label(for: viewModel.today?.score ?? 0))
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 6) {
                    let zones = viewModel.today?.zoneMinutes ?? [0, 0, 0, 0, 0]
                    let maxMinutes = max(zones.max() ?? 1, 1)
                    ForEach(Array(zones.enumerated().reversed()), id: \.offset) { index, minutes in
                        HStack(spacing: 8) {
                            Text(Self.zoneNames[index])
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Self.zoneColors[index])
                                .frame(width: 46, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.quaternary)
                                    Capsule()
                                        .fill(Self.zoneColors[index])
                                        .frame(width: max(geo.size.width * minutes / maxMinutes, minutes > 0 ? 4 : 0))
                                }
                            }
                            .frame(height: 7)
                            Text("\(Int(minutes.rounded())) min")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            if let energy = viewModel.todayActiveEnergy, let exercise = viewModel.todayExerciseMinutes {
                Text("\(Int(energy.rounded())) kcal actives · \(Int(exercise.rounded())) min d'exercice")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("14 derniers jours", systemImage: "chart.bar.fill")
                .font(.headline)
            Chart(viewModel.history, id: \.day) { day in
                BarMark(x: .value("Jour", day.day, unit: .day), y: .value("Effort", day.score))
                    .foregroundStyle(Self.severityColor(day.score))
                    .cornerRadius(2)
            }
            .chartYScale(domain: 0...100)
            .frame(height: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func severityColor(_ score: Double) -> Color {
        switch score {
        case 70...: return .red
        case 40..<70: return .orange
        default: return .green
        }
    }
}
