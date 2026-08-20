import SwiftUI
import Charts

struct BodyView: View {
    @ObservedObject var viewModel: BodyViewModel
    @State private var period: TrendPeriod = .oneYear

    private static let fatColor = Color.orange
    private static let leanColor = Color.cyan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let latest = viewModel.latest {
                    latestCard(latest)
                    metricsRow(latest)
                } else {
                    ContentUnavailableView(
                        "Aucune pesée en base",
                        systemImage: "scalemass",
                        description: Text("Importez un export Santé contenant des mesures de balance connectée.")
                    )
                }

                if !viewModel.snapshots.isEmpty {
                    Picker("Période", selection: $period) {
                        Text("3 mois").tag(TrendPeriod.threeMonths)
                        Text("6 mois").tag(TrendPeriod.sixMonths)
                        Text("1 an").tag(TrendPeriod.oneYear)
                        Text("Tout").tag(TrendPeriod.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    compositionChart
                    fatShareChart
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { try? viewModel.load(period: period) }
        .onChange(of: period) { _, newPeriod in
            try? viewModel.load(period: newPeriod)
        }
    }

    // MARK: - Dernière pesée

    @ViewBuilder
    private func latestCard(_ latest: BodySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dernière pesée").font(.title2.bold())
            Text(latest.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(latest.weight.formatted(.number.precision(.fractionLength(1))))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("kg").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        deltaLine(viewModel.weightDelta30d, label: "sur 30 jours")
                        deltaLine(viewModel.weightDelta1y, label: "sur 1 an")
                    }
                }

                if let fatMass = latest.fatMass, let leanMass = latest.leanMass {
                    compositionBar(fatMass: fatMass, leanMass: leanMass, weight: latest.weight)
                }
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
    }

    /// Barre de répartition masse grasse / masse maigre de la dernière pesée.
    @ViewBuilder
    private func compositionBar(fatMass: Double, leanMass: Double, weight: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Self.leanColor.gradient)
                        .frame(width: geo.size.width * leanMass / weight)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Self.fatColor.gradient)
                }
            }
            .frame(height: 14)

            HStack(spacing: 16) {
                legendDot(color: Self.leanColor, text: "Maigre \(formatKg(leanMass))")
                legendDot(color: Self.fatColor, text: "Graisse \(formatKg(fatMass)) (\((fatMass / weight).formatted(.percent.precision(.fractionLength(1)))))")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func deltaLine(_ delta: Double?, label: String) -> some View {
        if let delta {
            HStack(spacing: 4) {
                Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text("\(delta >= 0 ? "+" : "−")\(abs(delta).formatted(.number.precision(.fractionLength(1)))) kg")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(delta > 0 ? .red : .green)
        }
    }

    // MARK: - Cartes de mesures

    @ViewBuilder
    private func metricsRow(_ latest: BodySnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)], spacing: 12) {
            if let fatMass = latest.fatMass {
                MetricCard(style: .bodyFat, value: fatMass.formatted(.number.precision(.fractionLength(1))))
            }
            if let leanMass = latest.leanMass {
                MetricCard(style: .leanMass, value: leanMass.formatted(.number.precision(.fractionLength(1))))
            }
            if let fatShare = latest.fatShare {
                MetricCard(
                    style: MetricStyle(title: "Taux de graisse", unit: "", systemImage: "percent", tint: Self.fatColor),
                    value: fatShare.formatted(.percent.precision(.fractionLength(1)))
                )
            }
            if let bmi = latest.bmi {
                MetricCard(style: .bmi, value: bmi.formatted(.number.precision(.fractionLength(1))))
            }
        }
    }

    // MARK: - Graphiques

    /// Aires empilées masse maigre + masse grasse : la ligne de crête est le
    /// poids total, la répartition se lit dans l'épaisseur des bandes.
    private var compositionChart: some View {
        chartCard(title: "Composition corporelle") {
            Chart {
                ForEach(composedPoints, id: \.day) { point in
                    AreaMark(x: .value("Date", point.day), y: .value("kg", point.lean), stacking: .standard)
                        .foregroundStyle(by: .value("Masse", "Maigre"))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.day), y: .value("kg", point.fat), stacking: .standard)
                        .foregroundStyle(by: .value("Masse", "Graisse"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Maigre": Self.leanColor.opacity(0.75), "Graisse": Self.fatColor.opacity(0.85)])
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var fatShareChart: some View {
        chartCard(title: "Taux de graisse") {
            Chart {
                ForEach(viewModel.snapshots.filter { $0.fatShare != nil }, id: \.day) { point in
                    LineMark(x: .value("Date", point.day), y: .value("%", (point.fatShare ?? 0) * 100))
                        .foregroundStyle(Self.fatColor)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var composedPoints: [(day: Date, lean: Double, fat: Double)] {
        viewModel.snapshots.compactMap { snapshot in
            guard let lean = snapshot.leanMass, let fat = snapshot.fatMass else { return nil }
            return (snapshot.day, lean, fat)
        }
    }

    @ViewBuilder
    private func chartCard(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            content()
                .frame(height: 200)
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
                .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
    }

    private func formatKg(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) kg"
    }
}
