import SwiftUI

/// Écran affiché à la place de `ContentView` quand la base n'a pas pu
/// s'ouvrir au lancement. Il remplace l'interface entière plutôt que de se
/// superposer : l'import doit rester inatteignable tant que le store est
/// hors service.
struct StoreErrorView: View {
    let error: Error

    private var databasePath: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HealthCheck/health.sqlite").path
            ?? "~/Library/Application Support/HealthCheck/health.sqlite"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("Base de données inaccessible")
                .font(.title2.bold())

            Text("HealthCheck n'a pas pu ouvrir sa base locale. Vos données ne sont pas perdues : le fichier est simplement illisible pour l'instant.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)

            VStack(alignment: .leading, spacing: 8) {
                Text(error.localizedDescription)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Divider()
                Text(databasePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Text("Vérifiez l'espace disque disponible et les droits sur ce fichier, puis relancez l'application.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: databasePath)])
            }
        }
        .padding(40)
        .frame(minWidth: 620, minHeight: 520)
    }
}
