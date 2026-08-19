import SwiftUI

@main
struct HealthCheckApp: App {
    private let store: HealthStore
    @StateObject private var importViewModel: ImportViewModel
    @StateObject private var dashboardViewModel: DashboardViewModel

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthCheck", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("health.sqlite").path

        let store = try! HealthStore(path: dbPath)
        self.store = store
        _importViewModel = StateObject(wrappedValue: ImportViewModel(importer: HealthExportImporter(store: store)))
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(store: store, resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(importViewModel: importViewModel, dashboardViewModel: dashboardViewModel)
        }
    }
}
