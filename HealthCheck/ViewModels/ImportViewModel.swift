import Foundation

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var isImporting = false
    @Published var elementsProcessed = 0
    @Published var lastSummary: ImportSummary?
    @Published var lastError: String?

    private let importer: HealthExportImporter

    init(importer: HealthExportImporter) {
        self.importer = importer
    }

    func importZip(at url: URL) async {
        isImporting = true
        elementsProcessed = 0
        lastError = nil
        defer { isImporting = false }

        do {
            let summary = try await Task.detached(priority: .userInitiated) { [importer] in
                try importer.importZip(at: url, progress: { count in
                    Task { @MainActor in self.elementsProcessed = count }
                })
            }.value
            lastSummary = summary
        } catch {
            lastError = "\(error)"
        }
    }
}
