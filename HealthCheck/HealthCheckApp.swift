import SwiftUI

@main
struct HealthCheckApp: App {
    private let store: HealthStore
    @StateObject private var importViewModel: ImportViewModel
    @StateObject private var dashboardViewModel: DashboardViewModel
    @StateObject private var trendsViewModel: TrendsViewModel
    @StateObject private var sleepViewModel: SleepViewModel
    @StateObject private var activityViewModel: ActivityViewModel

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthCheck", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbPath = appSupport.appendingPathComponent("health.sqlite").path

        let store = try! HealthStore(path: dbPath)
        self.store = store
        let resolver = SourcePriorityResolver(priority: ["Watch", "iPhone"])
        _importViewModel = StateObject(wrappedValue: ImportViewModel(importer: HealthExportImporter(store: store)))
        _dashboardViewModel = StateObject(wrappedValue: DashboardViewModel(store: store, resolver: resolver))
        _trendsViewModel = StateObject(wrappedValue: TrendsViewModel(store: store, resolver: resolver))
        _sleepViewModel = StateObject(wrappedValue: SleepViewModel(store: store, resolver: resolver))
        _activityViewModel = StateObject(wrappedValue: ActivityViewModel(store: store, resolver: resolver))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                importViewModel: importViewModel,
                dashboardViewModel: dashboardViewModel,
                trendsViewModel: trendsViewModel,
                sleepViewModel: sleepViewModel,
                activityViewModel: activityViewModel
            )
        }
    }
}
