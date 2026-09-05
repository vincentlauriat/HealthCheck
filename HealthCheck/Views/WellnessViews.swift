import SwiftUI

/// Anneau de score 0-100, teinté selon la zone (rouge → orange → vert).
struct ScoreRingView: View {
    let score: Double
    @State private var animatedProgress: Double = 0

    private var tint: Color {
        switch score {
        case 70...: return .green
        case 50..<70: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.55), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * animatedProgress)
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(score.rounded()))")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/ 100")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 130, height: 130)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animatedProgress = score / 100 }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(.easeOut(duration: 0.5)) { animatedProgress = newScore / 100 }
        }
    }
}

/// Anneau de progression « données réunies », montré à la place du score quand
/// le moteur a refusé de conclure.
///
/// Volontairement distinct de `ScoreRingView` : sa teinte ne dépend d'aucune
/// valeur — il n'y a précisément rien à juger — et son remplissage mesure une
/// collecte, pas une performance. C'est ce qui le sépare d'un message d'erreur :
/// un anneau qui se remplit annonce une progression, là où « Score
/// indisponible » annonçait une panne.
struct ReadinessProgressRingView: View {
    let measuredWeight: Double
    @State private var animatedProgress: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(measuredWeight.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("réunis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 130, height: 130)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(measuredWeight.formatted(.percent.precision(.fractionLength(0)))) des données du score réunies")
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { animatedProgress = measuredWeight }
        }
        .onChange(of: measuredWeight) { _, newWeight in
            withAnimation(.easeOut(duration: 0.5)) { animatedProgress = newWeight }
        }
    }
}

/// Carte « Forme du jour » : anneau + détail des composantes avec mini-jauges.
struct ReadinessCard: View {
    let readiness: ReadinessScore

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(spacing: 8) {
                if readiness.isConclusive {
                    ScoreRingView(score: readiness.value)
                    Text(readiness.label)
                        .font(.subheadline.weight(.semibold))
                } else {
                    // Montrer le chiffre serait pire que ne rien montrer : il
                    // se lirait comme un verdict alors que la majorité du
                    // panier n'a pas été mesurée. Mais l'annoncer
                    // « indisponible » derrière un point d'interrogation le
                    // faisait passer pour une panne, alors qu'il ne manque que
                    // des données — et que la plupart reviennent en bougeant.
                    // L'anneau montre donc le chemin parcouru, et la colonne
                    // de droite ce qui débloque le reste.
                    ReadinessProgressRingView(measuredWeight: readiness.measuredWeight)
                    Text("Score en préparation")
                        .font(.subheadline.weight(.semibold))
                    Text("Il s'affiche à partir de \(HealthScoreEngine.minimumMeasuredWeight.formatted(.percent.precision(.fractionLength(0)))) de données réunies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 150)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(readiness.components, id: \.name) { component in
                    HStack(spacing: 10) {
                        Image(systemName: component.systemImage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(component.name).font(.callout.weight(.medium))
                                if let share = component.share {
                                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help("Part de cette composante dans le score, après redistribution du poids des composantes non mesurées.")
                                }
                                Spacer()
                                Text(component.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let depth = component.depthLabel {
                                    Text("· \(depth)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .help("Nombre d'échantillons derrière la valeur du jour. La moyenne se précise à mesure que la journée avance.")
                                }
                            }
                            ProgressView(value: component.score, total: 100)
                                .tint(component.score >= 70 ? .green : component.score >= 50 ? .orange : .red)
                                .controlSize(.small)
                        }
                    }
                }

                // Le score ne pénalise pas une composante absente, il
                // redistribue son poids. Sans cette liste, un score amputé du
                // sommeil affiche « Excellente forme » sans rien laisser voir.
                ForEach(readiness.missing, id: \.name) { missing in
                    HStack(spacing: 10) {
                        Image(systemName: missing.systemImage)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(missing.name).font(.callout.weight(.medium))
                                Spacer()
                                // « à débloquer » plutôt que « non mesuré » :
                                // les deux disent la même chose, mais l'un
                                // décrit un manque et l'autre ce qu'il reste
                                // à faire.
                                Text("à débloquer")
                                    .font(.caption)
                            }
                            if !missing.action.isEmpty {
                                Text(missing.action)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("\(missing.reason) · poids \(missing.nominalWeight.formatted(.percent.precision(.fractionLength(0)))) réparti sur les autres composantes.")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Text(HealthScoreEngine.formulaExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}

/// Carte d'insight : observation en langage naturel générée par le moteur.
struct InsightCard: View {
    let insight: Insight

    private var tint: Color {
        switch insight.sentiment {
        case .positive: return .green
        case .warning: return .orange
        case .neutral: return .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title).font(.callout.weight(.semibold))
                Text(insight.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}

/// Carte « Conseil du jour » : message unique et priorisé, dérivé du score
/// de forme et affiné par une alerte de charge/VO2max quand compatible
/// (DailyAdviceEngine.advise). Même gabarit visuel qu'InsightCard, teinté
/// par le palier plutôt que par le sentiment.
struct DailyAdviceCard: View {
    let advice: DailyAdvice

    private var tint: Color {
        switch advice.tier {
        case .repos: return .orange
        case .prudence: return .blue
        case .opportunite: return .green
        }
    }

    private var systemImage: String {
        switch advice.tier {
        case .repos: return "exclamationmark.triangle.fill"
        case .prudence: return "info.circle.fill"
        case .opportunite: return "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch advice.tier {
        case .repos: return "Repos conseillé"
        case .prudence: return "Prudence"
        case .opportunite: return "Opportunité"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(advice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}
