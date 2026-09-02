import SwiftUI

/// Anneau de score, équivalent iOS de `ScoreRingView` (macOS, non compilé par
/// cette cible). Trait plus fin et diamètre réduit : sur iPhone la carte est
/// deux fois plus étroite que sur le Mac.
struct CompanionScoreRingView: View {
    let score: Double

    private var tint: Color {
        switch score {
        case 70...: return .green
        case 50..<70: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(max(score / 100, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(score.rounded()))")
                .font(.title3.bold())
                .monospacedDigit()
        }
        .frame(width: 76, height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(Int(score.rounded())) sur 100")
    }
}
