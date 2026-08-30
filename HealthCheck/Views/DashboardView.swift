import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel

    private let columns = [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let readiness = viewModel.readiness {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Forme du jour").font(.title2.bold())
                            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ReadinessCard(readiness: readiness)
                    }
                }

                if let dailyAdvice = viewModel.dailyAdvice {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Conseil du jour").font(.title2.bold())
                        DailyAdviceCard(advice: dailyAdvice)
                    }
                }

                if !viewModel.insights.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Observations").font(.title2.bold())
                        ForEach(viewModel.insights, id: \.title) { insight in
                            InsightCard(insight: insight)
                        }
                    }
                }

                section(
                    title: "Aujourd'hui",
                    subtitle: viewModel.readiness == nil
                        ? Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
                        : nil,
                    summary: viewModel.today,
                    reference: nil
                )
                section(
                    title: "Cette semaine",
                    subtitle: viewModel.lastWeek != nil ? "Comparé à la même période la semaine dernière" : nil,
                    summary: viewModel.thisWeek,
                    reference: viewModel.lastWeek
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
    }

    @ViewBuilder
    private func section(title: String, subtitle: String?, summary: PeriodSummary?, reference: PeriodSummary?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if let summary {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    MetricCard(
                        style: .steps,
                        value: summary.steps.formatted(.number.precision(.fractionLength(0))),
                        delta: relativeDelta(summary.steps, reference?.steps)
                    )
                    MetricCard(
                        style: .distance,
                        value: summary.distanceKm.formatted(.number.precision(.fractionLength(0...1))),
                        delta: relativeDelta(summary.distanceKm, reference?.distanceKm)
                    )
                    MetricCard(
                        style: .activeEnergy,
                        value: summary.activeEnergyKcal.formatted(.number.precision(.fractionLength(0))),
                        delta: relativeDelta(summary.activeEnergyKcal, reference?.activeEnergyKcal)
                    )
                    MetricCard(
                        style: .exercise,
                        value: summary.exerciseMinutes.formatted(.number.precision(.fractionLength(0))),
                        delta: relativeDelta(summary.exerciseMinutes, reference?.exerciseMinutes)
                    )
                    MetricCard(
                        style: .restingHeartRate,
                        value: summary.restingHeartRate.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
                    )
                }
            } else {
                ContentUnavailableView(
                    "Aucune donnée",
                    systemImage: "heart.text.square",
                    description: Text("Importez un export Apple Santé pour voir vos métriques.")
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func relativeDelta(_ current: Double, _ previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return (current - previous) / previous
    }
}
