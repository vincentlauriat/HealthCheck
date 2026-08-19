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

/// Carte « Forme du jour » : anneau + détail des composantes avec mini-jauges.
struct ReadinessCard: View {
    let readiness: ReadinessScore

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(spacing: 8) {
                ScoreRingView(score: readiness.value)
                Text(readiness.label)
                    .font(.subheadline.weight(.semibold))
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
                                Spacer()
                                Text(component.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: component.score, total: 100)
                                .tint(component.score >= 70 ? .green : component.score >= 50 ? .orange : .red)
                                .controlSize(.small)
                        }
                    }
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
