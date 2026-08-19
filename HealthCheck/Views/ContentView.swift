import SwiftUI

enum SidebarSelection: Hashable {
    case dashboard
    case trends
}

struct ContentView: View {
    @ObservedObject var importViewModel: ImportViewModel
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @ObservedObject var trendsViewModel: TrendsViewModel
    @State private var selection: SidebarSelection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dashboard", systemImage: "chart.bar")
                    .tag(SidebarSelection.dashboard)
                Label("Tendances", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SidebarSelection.trends)
            }
        } detail: {
            switch selection {
            case .trends:
                TrendsView(viewModel: trendsViewModel)
            case .dashboard, .none:
                VStack(spacing: 0) {
                    ImportView(viewModel: importViewModel)
                    Divider()
                    DashboardView(viewModel: dashboardViewModel)
                }
            }
        }
        .onChange(of: importViewModel.lastSummary?.recordsInserted) { _, _ in
            try? dashboardViewModel.loadToday()
            try? dashboardViewModel.loadThisWeek()
        }
    }
}
