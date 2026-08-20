import SwiftUI
import Charts

struct SleepView: View {
    @ObservedObject var viewModel: SleepViewModel

    private static let phaseColors: KeyValuePairs<String, Color> = [
        "Profond": Color(red: 0.22, green: 0.20, blue: 0.65),
        "REM": .purple,
        "Léger": Color(red: 0.45, green: 0.62, blue: 0.95)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let last = viewModel.lastNight {
                    lastNightCard(last)
                } else {
                    ContentUnavailableView(
                        "Aucune nuit trackée récemment",
                        systemImage: "moon.zzz",
                        description: Text("Portez votre Apple Watch la nuit puis réimportez un export Santé.")
                    )
                }

                if !viewModel.nights.isEmpty {
                    nightsChart
                    averagesRow
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
    }

    @ViewBuilder
    private func lastNightCard(_ night: NightSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dernière nuit").font(.title2.bold())
            Text(night.night.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 28) {
                VStack(spacing: 8) {
                    ScoreRingView(score: night.score)
                    Text("Score de sommeil").font(.subheadline.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 10) {
                    phaseRow(name: "Durée totale", hours: night.asleepHours, tint: MetricStyle.sleep.tint, icon: "moon.zzz.fill")
                    phaseRow(name: "Profond", hours: night.deepHours, tint: Color(red: 0.22, green: 0.20, blue: 0.65), icon: "moon.fill")
                    phaseRow(name: "REM", hours: night.remHours, tint: .purple, icon: "sparkles")
                    phaseRow(name: "Léger", hours: night.coreHours, tint: Color(red: 0.45, green: 0.62, blue: 0.95), icon: "moon")
                    HStack(spacing: 10) {
                        Image(systemName: "eye.fill").font(.callout).foregroundStyle(.orange).frame(width: 20)
                        Text("Réveils").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(night.awakeCount)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
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

    @ViewBuilder
    private func phaseRow(name: String, hours: Double, tint: Color, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.callout).foregroundStyle(tint).frame(width: 20)
            Text(name).font(.callout.weight(.medium))
            Spacer()
            Text(Self.formatHours(hours)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var nightsChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("14 dernières nuits").font(.title2.bold())
            Chart {
                ForEach(viewModel.nights, id: \.night) { night in
                    BarMark(x: .value("Nuit", night.night, unit: .day), y: .value("Heures", night.deepHours))
                        .foregroundStyle(by: .value("Phase", "Profond"))
                    BarMark(x: .value("Nuit", night.night, unit: .day), y: .value("Heures", night.remHours))
                        .foregroundStyle(by: .value("Phase", "REM"))
                    BarMark(x: .value("Nuit", night.night, unit: .day), y: .value("Heures", night.coreHours))
                        .foregroundStyle(by: .value("Phase", "Léger"))
                }
                RuleMark(y: .value("Cible", SleepScoreEngine.targetHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .topTrailing) {
                        Text("Cible 8 h").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartForegroundStyleScale(Self.phaseColors)
            .frame(height: 200)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
    }

    private var averagesRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)], spacing: 12) {
            if let avg = viewModel.averageHours {
                MetricCard(style: .sleep, value: Self.formatHours(avg))
            }
            if let score = viewModel.averageScore {
                MetricCard(
                    style: MetricStyle(title: "Score moyen", unit: "/100", systemImage: "gauge.with.needle", tint: .indigo),
                    value: score.formatted(.number.precision(.fractionLength(0)))
                )
            }
            if let deep = viewModel.averageDeepShare {
                MetricCard(
                    style: MetricStyle(title: "Sommeil profond", unit: "", systemImage: "moon.fill", tint: Color(red: 0.22, green: 0.20, blue: 0.65)),
                    value: deep.formatted(.percent.precision(.fractionLength(0)))
                )
            }
            if let rem = viewModel.averageRemShare {
                MetricCard(
                    style: MetricStyle(title: "Sommeil REM", unit: "", systemImage: "sparkles", tint: .purple),
                    value: rem.formatted(.percent.precision(.fractionLength(0)))
                )
            }
        }
    }

    static func formatHours(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        return "\(totalMinutes / 60) h \(String(format: "%02d", totalMinutes % 60))"
    }
}
