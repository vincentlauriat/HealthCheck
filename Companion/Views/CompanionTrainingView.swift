import SwiftUI

/// Onglet « Entraînement » : charge et VO2max calculés localement
/// (`TrainingViewModel`). Les objectifs de course se créent sur le Mac, donc
/// `race_goal` est vide ici — sans objectif, le plan et la progression n'ont
/// pas de sens, mais le suivi de charge reste pertinent : c'est le mode
/// « entre deux courses », et c'est ce que l'écran affiche.
struct CompanionTrainingView: View {
    @ObservedObject var viewModel: TrainingViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let assessment = viewModel.assessment {
                    loadCard(assessment)
                }
                if let status = viewModel.vo2MaxStatus, status.trend != nil || status.alert != nil {
                    vo2Card(status)
                }
                if viewModel.assessment == nil && viewModel.vo2MaxStatus?.trend == nil {
                    ContentUnavailableView(
                        "Pas encore de séance enregistrée",
                        systemImage: "figure.run",
                        description: Text("Vos sorties apparaîtront ici dès qu'elles seront enregistrées dans Santé.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private func loadCard(_ assessment: LoadAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Charge d'entraînement", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)
            LabeledContent("7 derniers jours",
                           value: "\(assessment.acuteKm.formatted(.number.precision(.fractionLength(1)))) km")
            LabeledContent("Moyenne hebdomadaire",
                           value: "\(assessment.chronicWeeklyKm.formatted(.number.precision(.fractionLength(1)))) km")
            if let acwr = assessment.acwr {
                LabeledContent("Rapport aigu/chronique",
                               value: acwr.formatted(.number.precision(.fractionLength(2))))
            }
            ForEach(Array(assessment.alerts.enumerated()), id: \.offset) { _, alert in
                alertLabel(alert)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func vo2Card(_ status: VO2MaxStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("VO2max", systemImage: "lungs.fill")
                .font(.headline)
            if let trend = status.trend {
                Text("\(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) mL/min·kg")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel("VO2max \(trend.recentAverage.formatted(.number.precision(.fractionLength(1)))) millilitres par minute et par kilo")
            }
            if let alert = status.alert {
                alertLabel(alert)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func alertLabel(_ alert: LoadAlert) -> some View {
        Label(alert.message,
              systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.callout)
            .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
