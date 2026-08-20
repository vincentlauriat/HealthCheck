import SwiftUI

/// Carte de connexion/synchronisation Withings de l'écran Données.
struct WithingsCard: View {
    @ObservedObject var viewModel: WithingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "scalemass.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 34, height: 34)
                    .background(.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Withings").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            HStack(spacing: 10) {
                switch viewModel.status {
                case .unconfigured:
                    EmptyView()
                case .disconnected, .error:
                    Button("Connecter Withings") { viewModel.connect() }
                        .buttonStyle(.borderedProminent)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Autorisation dans le navigateur…").font(.caption).foregroundStyle(.secondary)
                case .connected:
                    Button("Synchroniser") { viewModel.sync() }
                        .buttonStyle(.borderedProminent)
                    Button("Déconnecter") { viewModel.disconnect() }
                        .buttonStyle(.bordered)
                case .syncing:
                    ProgressView().controlSize(.small)
                    Text("Synchronisation…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if case .error(let message) = viewModel.status {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if let summary = viewModel.lastSyncSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            } else if let last = viewModel.lastSyncDate {
                Text("Dernière synchro : \(last.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_FR"))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }

    private var subtitle: String {
        switch viewModel.status {
        case .unconfigured:
            return "Configuration absente (withings.json)"
        case .disconnected:
            return "Composition corporelle complète : muscle, eau, os, graisse viscérale"
        default:
            return "Lecture directe depuis le cloud Withings"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch viewModel.status {
        case .connected, .syncing:
            Label("Connecté", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        case .unconfigured:
            Label("Non configuré", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}
