import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case sleep
    case activity
    case workouts
    case body
    case trends
    case data
}

struct ContentView: View {
    @ObservedObject var importViewModel: ImportViewModel
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @ObservedObject var trendsViewModel: TrendsViewModel
    @ObservedObject var sleepViewModel: SleepViewModel
    @ObservedObject var activityViewModel: ActivityViewModel
    @ObservedObject var bodyViewModel: BodyViewModel
    @ObservedObject var withingsViewModel: WithingsViewModel
    @ObservedObject var workoutsViewModel: WorkoutsViewModel
    @State private var selection: SidebarSelection? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Analyse") {
                    Label("Accueil", systemImage: "house.fill")
                        .tag(SidebarSelection.home)
                    Label("Sommeil", systemImage: "moon.zzz.fill")
                        .tag(SidebarSelection.sleep)
                    Label("Effort", systemImage: "flame.fill")
                        .tag(SidebarSelection.activity)
                    Label("Séances", systemImage: "figure.run")
                        .tag(SidebarSelection.workouts)
                    Label("Corps", systemImage: "scalemass.fill")
                        .tag(SidebarSelection.body)
                    Label("Tendances", systemImage: "chart.line.uptrend.xyaxis")
                        .tag(SidebarSelection.trends)
                }
                Section("Bibliothèque") {
                    Label("Données", systemImage: "square.and.arrow.down.on.square")
                        .tag(SidebarSelection.data)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            switch selection {
            case .sleep:
                SleepView(viewModel: sleepViewModel)
                    .navigationTitle("Sommeil")
            case .activity:
                ActivityView(viewModel: activityViewModel)
                    .navigationTitle("Effort")
            case .workouts:
                WorkoutsView(viewModel: workoutsViewModel)
                    .navigationTitle("Séances")
            case .body:
                BodyView(viewModel: bodyViewModel)
                    .navigationTitle("Corps")
            case .trends:
                TrendsView(viewModel: trendsViewModel)
                    .navigationTitle("Tendances")
            case .data:
                VStack(spacing: 20) {
                    Spacer()
                    ImportView(viewModel: importViewModel)
                        .frame(maxWidth: 560)
                    WithingsCard(viewModel: withingsViewModel)
                        .frame(maxWidth: 560)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .navigationTitle("Données")
            case .home, .none:
                DashboardView(viewModel: dashboardViewModel)
                    .navigationTitle("Accueil")
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .onChange(of: importViewModel.lastSummary?.recordsInserted) { _, _ in
            try? dashboardViewModel.loadToday()
            try? dashboardViewModel.loadThisWeek()
            try? dashboardViewModel.loadWellness()
            try? sleepViewModel.load()
            try? activityViewModel.load()
            try? bodyViewModel.load(period: .oneYear)
            try? workoutsViewModel.load()
        }
        .onChange(of: withingsViewModel.syncGeneration) { _, _ in
            try? dashboardViewModel.loadToday()
            try? dashboardViewModel.loadThisWeek()
            try? dashboardViewModel.loadWellness()
            try? bodyViewModel.load(period: .oneYear)
            try? trendsViewModel.load(period: .sixMonths)
        }
    }
}
