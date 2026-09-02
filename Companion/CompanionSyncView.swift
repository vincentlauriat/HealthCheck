import SwiftUI

/// Écran « Réglages » : appairage au Mac, statut de synchronisation,
/// dépairage. Rien d'autre — le plan d'entraînement en cache, qui vivait ici,
/// est passé dans l'onglet Entraînement au SP3 : l'appairage est une
/// configuration, le plan est un contenu quotidien.
struct CompanionSyncView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @State private var code = ""
    @State private var showUnpairConfirmation = false

    var body: some View {
        Group {
            if viewModel.isPaired {
                pairedContent
            } else {
                pairingContent
            }
        }
        .confirmationDialog(
            "Oublier ce Mac ?",
            isPresented: $showUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Oublier", role: .destructive) {
                viewModel.unpair()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L'appairage sera supprimé et la synchronisation s'arrêtera. Vous devrez saisir un nouveau code depuis votre Mac pour la reprendre.")
        }
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                syncCard

                if let error = viewModel.errorMessage {
                    warningCard(error)
                }

                Button("Oublier ce Mac", role: .destructive) {
                    showUnpairConfirmation = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var pairingContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Appairage Mac", systemImage: "macbook.and.iphone")
                        .font(.title3.weight(.semibold))
                    Text("Sur votre Mac : HealthCheck > Données > carte iPhone > Appairer, puis saisissez le code ici.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Code à 6 chiffres", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        Task { await viewModel.submitPairingCode(code) }
                    } label: {
                        Label("Appairer", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(code.count != 6)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 8))

                if let error = viewModel.errorMessage {
                    warningCard(error)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Appairé", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                if viewModel.isSyncing {
                    ProgressView()
                }
            }

            if let last = viewModel.lastSyncDate {
                LabeledContent("Dernier envoi", value: last.formatted(.relative(presentation: .named)))
                    .font(.callout)
            }

            if let summary = viewModel.lastReportSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.syncNow() }
            } label: {
                Label(viewModel.isSyncing ? "Envoi en cours" : "Envoyer au Mac", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(viewModel.isSyncing)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func warningCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
