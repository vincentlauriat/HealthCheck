import SwiftUI
import Charts

/// Onglet « Corps » : poids et masse grasse seulement. Ni Sankey ni
/// composition corporelle — muscle, eau, os et graisse viscérale ne
/// transitent que par l'API Withings, que l'iPhone n'appelle pas (spec §6).
///
/// La date de la dernière pesée est affichée en clair et non déduite : la
/// synchro Withings → Santé est en panne depuis le 18 juin 2026, donc l'écran
/// montre couramment une valeur de plusieurs semaines. La donner pour la
/// valeur du jour serait le vrai défaut.
struct CompanionBodyView: View {
    @ObservedObject var viewModel: BodyViewModel
    @State private var period: TrendPeriod = .threeMonths

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                // Trois états distincts, et pas deux : avant la fin du premier
                // chargement, `latest` est nul sans que ce soit une absence de
                // données. Le confondre avec le cas « aucune pesée » afficherait
                // une carte vide et un graphique vide le temps de la lecture.
                if !viewModel.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if viewModel.latest == nil {
                    noDataCard
                } else {
                    latestCard
                    if let trajectory = viewModel.weightTrajectory { trajectoryCard(trajectory) }
                    if let alert = viewModel.weightSafetyAlert { alertCard(alert) }
                    periodPicker
                    weightChartCard
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load(period: period) } }
        .onChange(of: period) { _, newPeriod in try? viewModel.load(period: newPeriod) }
        .refreshable { try? viewModel.load(period: period) }
    }

    private var noDataCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Aucune pesée", systemImage: "scalemass")
                .font(.headline)
            Text("Aucune pesée n'a été trouvée dans Santé. Vérifie que HealthCheck a bien l'autorisation de lire le poids, dans Réglages › Santé › Accès aux données.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Chaque chiffre n'apparaît que s'il existe : une masse grasse absente
    /// n'est pas une masse grasse nulle.
    @ViewBuilder
    private var latestCard: some View {
        if let latest = viewModel.latest {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(MetricStyle.weight.title, systemImage: MetricStyle.weight.systemImage)
                        .font(.headline)
                        .foregroundStyle(MetricStyle.weight.tint)
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(latest.weight.formatted(.number.precision(.fractionLength(1))))
                            .font(.title2.bold())
                            .monospacedDigit()
                        Text("kg").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Dernière pesée le \(latest.day.formatted(.dateTime.day().month(.wide).year()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let fatShare = latest.fatShare {
                    row(MetricStyle.bodyFat.title,
                        value: (fatShare * 100).formatted(.number.precision(.fractionLength(1))) + " %")
                }
                if let fatMass = latest.fatMass {
                    row("Masse grasse", value: fatMass.formatted(.number.precision(.fractionLength(1))) + " kg")
                }
                if let leanMass = latest.leanMass {
                    row(MetricStyle.leanMass.title,
                        value: leanMass.formatted(.number.precision(.fractionLength(1))) + " kg")
                }

                if let delta30 = viewModel.weightDelta30d {
                    row("Sur 30 jours", value: signed(delta30) + " kg")
                }
                if let delta1y = viewModel.weightDelta1y {
                    row("Sur 1 an", value: signed(delta1y) + " kg")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func trajectoryCard(_ trajectory: WeightTrajectory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Objectif de poids", systemImage: "target")
                .font(.headline)
            Text("\(trajectory.requiredWeeklyRateKg.formatted(.number.precision(.fractionLength(2)))) kg/semaine sur \(trajectory.weeksRemaining.formatted(.number.precision(.fractionLength(0)))) semaines")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func alertCard(_ alert: LoadAlert) -> some View {
        Label(alert.message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var periodPicker: some View {
        Picker("Période", selection: $period) {
            ForEach(TrendPeriod.companionCases, id: \.self) { period in
                Text(period.label).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var weightChartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Poids")
                .font(.headline)
                .foregroundStyle(MetricStyle.weight.tint)
            if viewModel.snapshots.isEmpty {
                Text("Aucune pesée sur cette période.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                Chart(viewModel.snapshots, id: \.day) { snapshot in
                    LineMark(x: .value("Date", snapshot.day), y: .value("Poids", snapshot.weight))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(MetricStyle.weight.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 170)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private func signed(_ value: Double) -> String {
        value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)))
    }
}
