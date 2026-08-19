import SwiftUI

/// Identité visuelle d'une métrique de santé : libellé, unité, symbole, teinte.
/// Partagé entre le dashboard (cartes) et les tendances (graphiques) pour que
/// chaque métrique garde la même couleur partout dans l'app.
struct MetricStyle {
    let title: String
    let unit: String
    let systemImage: String
    let tint: Color

    static let steps = MetricStyle(title: "Pas", unit: "", systemImage: "figure.walk", tint: .orange)
    static let distance = MetricStyle(title: "Distance", unit: "km", systemImage: "location.fill", tint: .teal)
    static let activeEnergy = MetricStyle(title: "Calories actives", unit: "kcal", systemImage: "flame.fill", tint: .red)
    static let exercise = MetricStyle(title: "Exercice", unit: "min", systemImage: "figure.run", tint: .green)
    static let restingHeartRate = MetricStyle(title: "FC repos", unit: "bpm", systemImage: "heart.fill", tint: .pink)
    static let weight = MetricStyle(title: "Poids", unit: "kg", systemImage: "scalemass.fill", tint: .purple)
    static let vo2Max = MetricStyle(title: "VO₂ max", unit: "ml/kg/min", systemImage: "lungs.fill", tint: .mint)
    static let sleep = MetricStyle(title: "Sommeil", unit: "h/nuit", systemImage: "moon.zzz.fill", tint: .indigo)
}

/// Carte de métrique du dashboard : icône teintée, valeur en grand,
/// et badge de tendance optionnel (comparaison avec la période précédente).
struct MetricCard: View {
    let style: MetricStyle
    let value: String
    var delta: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: style.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(style.tint)
                    .frame(width: 30, height: 30)
                    .background(style.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                Text(style.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if !style.unit.isEmpty {
                    Text(style.unit)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let delta {
                    DeltaBadge(delta: delta)
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}

/// Badge « ▲ +12 % » / « ▼ −8 % » comparant à la période précédente.
struct DeltaBadge: View {
    let delta: Double

    private var isUp: Bool { delta >= 0 }

    var body: some View {
        Label(
            abs(delta).formatted(.percent.precision(.fractionLength(0))),
            systemImage: isUp ? "arrow.up.right" : "arrow.down.right"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(isUp ? Color.green : Color.red)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((isUp ? Color.green : Color.red).opacity(0.12), in: Capsule())
        .help("Par rapport à la semaine précédente")
    }
}
