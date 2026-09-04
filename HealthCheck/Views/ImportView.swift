import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @ObservedObject var viewModel: ImportViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                    )

                VStack(spacing: 10) {
                    if viewModel.isImporting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Import en cours… \(viewModel.elementsProcessed.formatted()) éléments")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 28))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                        Text("Glissez votre export Apple Santé (.zip) ici")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Choisir un fichier…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [UTType.zip]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                Task { await viewModel.importZip(at: url) }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 130)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [UTType.zip], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.zip.identifier) { url, _, _ in
                    guard let url else { return }
                    Task { @MainActor in await viewModel.importZip(at: url) }
                }
                return true
            }

            if let summary = viewModel.lastSummary {
                let seen = summary.recordsSeen + summary.workoutsSeen + summary.sleepRecordsSeen
                let inserted = summary.recordsInserted + summary.workoutsInserted + summary.sleepRecordsInserted
                Label(
                    "\(seen.formatted()) éléments traités, \(inserted.formatted()) nouveaux",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)

                // Sans cette ligne, un import qui ne fait que compléter des
                // séances déjà connues annonce « 0 nouveaux » et donne à
                // croire qu'il n'a rien fait.
                if summary.workoutsEnriched > 0 {
                    Label(
                        "\(summary.workoutsEnriched.formatted()) séances complétées (distance, énergie ou trace jusque-là manquantes)",
                        systemImage: "arrow.triangle.merge"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
