import SwiftUI

struct ContentView: View {
    @ObservedObject var importViewModel: ImportViewModel
    @ObservedObject var dashboardViewModel: DashboardViewModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("Dashboard", systemImage: "chart.bar")
            }
        } detail: {
            VStack(spacing: 0) {
                ImportView(viewModel: importViewModel)
                Divider()
                DashboardView(viewModel: dashboardViewModel)
            }
        }
        .onChange(of: importViewModel.lastSummary?.recordsInserted) { _, _ in
            try? dashboardViewModel.loadToday()
            try? dashboardViewModel.loadThisWeek()
        }
    }
}
