import SwiftUI
import Charts

/// Onglet « Sommeil » : dernière nuit détaillée par phases, historique des
/// 14 dernières nuits et moyennes, calculés localement par `SleepViewModel`
/// (partagé avec le Mac).
struct CompanionSleepView: View {
    @ObservedObject var viewModel: SleepViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let last = viewModel.lastNight {
                    lastNightCard(last)
                } else {
                    ContentUnavailableView(
                        "Aucune nuit enregistrée",
                        systemImage: "moon.zzz",
                        description: Text("Portez votre montre la nuit : les phases de sommeil viennent de Santé.")
                    )
                    .padding(.top, 40)
                }
                if !viewModel.nights.isEmpty {
                    nightsCard
                    averagesCard
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private func lastNightCard(_ night: NightSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Dernière nuit", systemImage: "moon.zzz.fill")
                .font(.headline)
            Text(night.night.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                CompanionScoreRingView(score: night.score)
                VStack(alignment: .leading, spacing: 6) {
                    phaseRow("Durée totale", hours: night.asleepHours, tint: .indigo, icon: "moon.zzz.fill")
                    phaseRow("Profond", hours: night.deepHours, tint: .indigo, icon: "moon.fill")
                    phaseRow("REM", hours: night.remHours, tint: .purple, icon: "sparkles")
                    phaseRow("Léger", hours: night.coreHours, tint: .blue, icon: "moon")
                    HStack(spacing: 8) {
                        Image(systemName: "eye.fill").font(.caption).foregroundStyle(.orange).frame(width: 18)
                        Text("Réveils").font(.caption.weight(.medium))
                        Spacer()
                        Text("\(night.awakeCount)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func phaseRow(_ name: String, hours: Double, tint: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint).frame(width: 18)
            Text(name).font(.caption.weight(.medium))
            Spacer()
            Text(Self.formatHours(hours)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var nightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("14 dernières nuits", systemImage: "chart.bar.fill")
                .font(.headline)
            Chart(viewModel.nights, id: \.night) { night in
                BarMark(x: .value("Nuit", night.night, unit: .day),
                        y: .value("Heures", night.asleepHours))
                    .foregroundStyle(.indigo)
                    .cornerRadius(2)
            }
            .frame(height: 160)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var averagesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Moyennes", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
            if let hours = viewModel.averageHours {
                LabeledContent("Durée", value: Self.formatHours(hours))
            }
            if let score = viewModel.averageScore {
                LabeledContent("Score", value: "\(Int(score.rounded())) / 100")
            }
            if let deep = viewModel.averageDeepShare {
                LabeledContent("Profond", value: "\(Int((deep * 100).rounded())) %")
            }
            if let rem = viewModel.averageRemShare {
                LabeledContent("REM", value: "\(Int((rem * 100).rounded())) %")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private static func formatHours(_ hours: Double) -> String {
        let total = Int((hours * 60).rounded())
        return "\(total / 60) h \(String(format: "%02d", total % 60))"
    }
}
