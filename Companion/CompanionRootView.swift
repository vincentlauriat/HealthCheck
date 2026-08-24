import SwiftUI

/// L'unique écran : appairage ou synchro selon l'état.
struct CompanionRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @State private var code = ""
    @State private var showUnpairConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isPaired {
                    syncSection
                    unpairSection
                } else {
                    pairingSection
                }
                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("HealthCheck")
            // Attaché au Form plutôt qu'à unpairSection : la section qui
            // porte le bouton disparaît (isPaired passe à false) dès que
            // l'action « Oublier » s'exécute, alors qu'elle contiendrait
            // encore la présentation du dialogue si elle en restait la
            // propriétaire.
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
    }

    private var unpairSection: some View {
        Section {
            Button("Oublier ce Mac", role: .destructive) {
                showUnpairConfirmation = true
            }
        }
    }

    private var pairingSection: some View {
        Section("Appairage") {
            Text("Sur votre Mac : HealthCheck → Données → carte iPhone → « Appairer… », puis saisissez le code ici.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Code à 6 chiffres", text: $code)
                .keyboardType(.numberPad)
                .font(.system(.title2, design: .monospaced))
            Button("Appairer") {
                Task { await viewModel.submitPairingCode(code) }
            }
            .disabled(code.count != 6)
            .buttonStyle(.borderedProminent)
        }
    }

    private var syncSection: some View {
        Section("Synchronisation") {
            HStack {
                Label("Appairé", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
            if let last = viewModel.lastSyncDate {
                LabeledContent("Dernière synchro",
                               value: last.formatted(.relative(presentation: .named)))
            }
            if let summary = viewModel.lastReportSummary {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await viewModel.syncNow() }
            } label: {
                if viewModel.isSyncing {
                    HStack { ProgressView(); Text("Synchronisation…") }
                } else {
                    Text("Synchroniser")
                }
            }
            .disabled(viewModel.isSyncing)
            .buttonStyle(.borderedProminent)
        }
    }
}
