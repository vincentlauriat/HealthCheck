import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @ObservedObject var viewModel: ImportViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            if viewModel.isImporting {
                ProgressView("Import en cours… \(viewModel.elementsProcessed) éléments")
            } else if let summary = viewModel.lastSummary {
                Text("\(summary.recordsSeen + summary.workoutsSeen) éléments traités, \(summary.recordsInserted + summary.workoutsInserted) nouveaux")
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.lastError {
                Text(error).foregroundStyle(.red)
            }

            Button("Importer un export Santé…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType.zip]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    Task { await viewModel.importZip(at: url) }
                }
            }
            .disabled(viewModel.isImporting)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onDrop(of: [UTType.zip], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.zip.identifier) { url, _, _ in
                guard let url else { return }
                Task { @MainActor in await viewModel.importZip(at: url) }
            }
            return true
        }
    }
}
