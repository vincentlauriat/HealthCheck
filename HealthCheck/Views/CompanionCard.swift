import SwiftUI

/// Carte d'appairage iPhone de l'écran Données.
struct CompanionCard: View {
    @ObservedObject var viewModel: CompanionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone").font(.headline)
                    Text("Synchronisation directe depuis votre iPhone (réseau local)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            if let code = viewModel.pairingCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saisissez ce code dans l'app HealthCheck Companion :")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(.title, design: .monospaced).bold())
                            .textSelection(.enabled)
                        Button("Annuler") { viewModel.cancelPairing() }
                            .buttonStyle(.bordered)
                    }
                }
            } else if viewModel.isPaired {
                HStack(spacing: 10) {
                    Button("Ré-appairer…") { viewModel.beginPairing() }
                        .buttonStyle(.bordered)
                    Button("Dissocier") { viewModel.unpair() }
                        .buttonStyle(.bordered)
                }
            } else {
                Button("Appairer…") { viewModel.beginPairing() }
                    .buttonStyle(.borderedProminent)
            }

            if let last = viewModel.lastSyncDate {
                Text("Dernière synchro : \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if viewModel.isPaired {
            Label("Appairé", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.green)
        } else {
            Label("Non appairé", systemImage: "circle.dashed")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
