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
    static let bodyFat = MetricStyle(title: "Masse grasse", unit: "kg", systemImage: "chart.pie.fill", tint: .orange)
    static let leanMass = MetricStyle(title: "Masse maigre", unit: "kg", systemImage: "figure.arms.open", tint: .cyan)
    static let bmi = MetricStyle(title: "IMC", unit: "", systemImage: "gauge.with.needle", tint: .brown)
    static let acuteLoad = MetricStyle(title: "Charge aiguë (7 j)", unit: "km", systemImage: "bolt.heart.fill", tint: .orange)
    static let chronicLoad = MetricStyle(title: "Charge chronique (4 sem)", unit: "km/sem", systemImage: "chart.bar.fill", tint: .blue)
    static let loadRatio = MetricStyle(title: "Ratio ACWR", unit: "", systemImage: "gauge.with.needle", tint: .purple)
}
