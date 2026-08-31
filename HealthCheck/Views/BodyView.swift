import SwiftUI
import Charts

struct BodyView: View {
    @ObservedObject var viewModel: BodyViewModel
    @State private var period: TrendPeriod = .oneYear
    @State private var goalWeightText = ""
    @State private var goalTargetDate = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    @State private var errorMessage: String?
    @State private var showingDeleteGoalConfirmation = false

    private static let fatColor = Color.orange
    private static let leanColor = Color.cyan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let latest = viewModel.latest {
                    latestCard(latest)
                    metricsRow(latest)
                    if let sankey = viewModel.weightSankey {
                        sankeyCard(sankey)
                    }
                    if let trend = viewModel.weightTrend {
                        trendCard(trend)
                    }
                    goalCard
                } else {
                    ContentUnavailableView(
                        "Aucune pesée en base",
                        systemImage: "scalemass",
                        description: Text("Importez un export Santé contenant des mesures de balance connectée.")
                    )
                }

                if !viewModel.snapshots.isEmpty {
                    Picker("Période", selection: $period) {
                        Text("1 semaine").tag(TrendPeriod.oneWeek)
                        Text("1 mois").tag(TrendPeriod.oneMonth)
                        Text("3 mois").tag(TrendPeriod.threeMonths)
                        Text("6 mois").tag(TrendPeriod.sixMonths)
                        Text("1 an").tag(TrendPeriod.oneYear)
                        Text("Tout").tag(TrendPeriod.all)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    compositionChart
                    compositionLegend
                    fatShareChart
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !viewModel.hasLoaded { try? viewModel.load(period: period) } }
        .onChange(of: period) { _, newPeriod in
            try? viewModel.load(period: newPeriod)
        }
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Supprimer cet objectif ?", isPresented: $showingDeleteGoalConfirmation,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { deleteWeightGoal() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est irréversible.")
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
            if let muscle = viewModel.latestMuscleMass {
                MetricCard(
                    style: MetricStyle(title: "Muscle", unit: "kg", systemImage: "figure.strengthtraining.traditional", tint: .red),
                    value: muscle.formatted(.number.precision(.fractionLength(1)))
                )
            }
            if let water = viewModel.latestHydration {
                MetricCard(
                    style: MetricStyle(title: "Eau", unit: "kg", systemImage: "drop.fill", tint: .blue),
                    value: water.formatted(.number.precision(.fractionLength(1)))
                )
            }
            if let bone = viewModel.latestBoneMass {
                MetricCard(
                    style: MetricStyle(title: "Os", unit: "kg", systemImage: "figure.stand", tint: .gray),
                    value: bone.formatted(.number.precision(.fractionLength(1)))
                )
            }
            if let visceral = viewModel.latestVisceralFat {
                MetricCard(
                    style: MetricStyle(title: "Graisse viscérale", unit: "", systemImage: "exclamationmark.circle", tint: .orange),
                    value: visceral.formatted(.number.precision(.fractionLength(1)))
                )
            }
        }
    }

    // MARK: - Sankey

    @ViewBuilder
    private func sankeyCard(_ sankey: WeightSankey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Répartition du poids").font(.title2.bold())
            WeightSankeyView(sankey: sankey)
                .frame(height: 240)
                .padding(.vertical, 8)
            if let water = viewModel.latestHydration {
                Label {
                    Text("Eau corporelle : \(water.formatted(.number.precision(.fractionLength(1)))) kg (\((water / sankey.totalKg).formatted(.percent.precision(.fractionLength(0))))) — transversale : contenue dans le muscle et les organes, elle ne s'additionne pas aux compartiments ci-dessus.")
                } icon: {
                    Image(systemName: "drop.fill").foregroundStyle(.blue)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: 640)
    }

    // MARK: - Tendance et objectif de poids

    @ViewBuilder
    private func trendCard(_ trend: WeightTrend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tendance").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(trendLabel(trend.direction)).font(.callout.weight(.semibold))
                Text("\(trend.weeklyRateKg >= 0 ? "+" : "")\(trend.weeklyRateKg.formatted(.number.precision(.fractionLength(2)))) kg/semaine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let alert = viewModel.weightSafetyAlert {
                Label(alert.message,
                     systemImage: alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(alert.severity == .warning ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
    }

    private func trendLabel(_ direction: WeightDirection) -> String {
        switch direction {
        case .losing: return "Poids en baisse"
        case .gaining: return "Poids en hausse"
        case .stable: return "Poids stable"
        }
    }

    @ViewBuilder
    private var goalCard: some View {
        if let goal = viewModel.weightGoal {
            VStack(alignment: .leading, spacing: 10) {
                Text("Objectif").font(.title2.bold())
                Text("\(goal.targetWeightKg.formatted(.number.precision(.fractionLength(1)))) kg pour le \(goal.targetDate.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))")
                    .font(.callout.weight(.semibold))
                if let trajectory = viewModel.weightTrajectory {
                    Text(trajectoryLabel(trajectory.verdict))
                        .font(.callout)
                        .foregroundStyle(trajectoryColor(trajectory.verdict))
                    Text("Rythme requis \(trajectory.requiredWeeklyRateKg.formatted(.number.precision(.fractionLength(2)))) kg/semaine · \(Int(trajectory.weeksRemaining.rounded())) semaines restantes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Supprimer l'objectif", role: .destructive) {
                    showingDeleteGoalConfirmation = true
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        } else {
            createGoalForm
        }
    }

    private var createGoalForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Définir un objectif de poids").font(.title2.bold())

            TextField("Poids cible (kg)", text: $goalWeightText)
                .textFieldStyle(.roundedBorder)

            DatePicker("Date cible", selection: $goalTargetDate, in: Date()...,
                      displayedComponents: .date)

            Button("Créer") { createWeightGoal() }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateWeightGoal)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .frame(maxWidth: 460)
    }

    private var parsedGoalWeightKg: Double {
        Double(goalWeightText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canCreateWeightGoal: Bool {
        parsedGoalWeightKg > 0 && goalTargetDate > Date()
    }

    private func createWeightGoal() {
        do {
            try viewModel.createWeightGoal(targetWeightKg: parsedGoalWeightKg, targetDate: goalTargetDate)
            try viewModel.load(period: period)
            goalWeightText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteWeightGoal() {
        do {
            try viewModel.deleteActiveWeightGoal()
            try viewModel.load(period: period)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trajectoryLabel(_ verdict: TrajectoryVerdict) -> String {
        switch verdict {
        case .onTrack: return "En bonne voie"
        case .tooSlow: return "Rythme insuffisant pour atteindre l'objectif à temps"
        case .tooFast: return "Rythme plus rapide que nécessaire"
        }
    }

    private func trajectoryColor(_ verdict: TrajectoryVerdict) -> Color {
        switch verdict {
        case .onTrack: return .green
        case .tooSlow, .tooFast: return .orange
        }
    }

    // MARK: - Graphiques

    /// Courbe du poids total et courbe de la masse maigre, bande de graisse
    /// entre les deux. Pas d'empilement depuis 0 : l'axe est resserré sur la
    /// zone utile (une variation de 2 kg doit se voir).
    private var compositionChart: some View {
        chartCard(title: "Composition corporelle") {
            Chart {
                ForEach(composedPoints, id: \.day) { point in
                    AreaMark(
                        x: .value("Date", point.day),
                        yStart: .value("Maigre", point.lean),
                        yEnd: .value("Poids", point.lean + point.fat)
                    )
                    .foregroundStyle(Self.fatColor.opacity(0.28))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Date", point.day),
                        y: .value("kg", point.lean + point.fat),
                        series: .value("Série", "Poids")
                    )
                    .foregroundStyle(Self.fatColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    LineMark(
                        x: .value("Date", point.day),
                        y: .value("kg", point.lean),
                        series: .value("Série", "Maigre")
                    )
                    .foregroundStyle(Self.leanColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    private var compositionLegend: some View {
        HStack(spacing: 16) {
            legendDot(color: Self.fatColor, text: "Poids total (bande = graisse)")
            legendDot(color: Self.leanColor, text: "Masse maigre")
            Spacer()
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
