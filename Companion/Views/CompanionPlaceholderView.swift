import SwiftUI

/// Écran d'attente des onglets posés au SP1 et remplis aux sous-projets
/// suivants. Dit ce qui manque plutôt que d'afficher un vide qu'on pourrait
/// prendre pour une panne.
struct CompanionPlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text("Cet écran arrive dans une prochaine version.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
    }
}
