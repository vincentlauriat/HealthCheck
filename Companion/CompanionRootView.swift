import SwiftUI

/// Shell de navigation à cinq onglets. « Accueil » est autonome (calcul
/// local, indépendant de l'appairage) ; les quatre autres sont posés ici et
/// remplis aux sous-projets suivants. L'appairage et l'envoi au Mac, qui
/// étaient un onglet, deviennent un écran de réglages : c'est une
/// configuration, pas une destination quotidienne.
struct CompanionRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var advisorViewModel: CompanionAdvisorViewModel
    @ObservedObject var activityViewModel: ActivityViewModel
    @ObservedObject var sleepViewModel: SleepViewModel
    @ObservedObject var trainingViewModel: TrainingViewModel
    @State private var showingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                CompanionAdvisorView(viewModel: advisorViewModel, lastSyncDate: viewModel.lastSyncDate)
                    .navigationTitle("Accueil")
                    .toolbar {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Réglages", systemImage: "gearshape")
                        }
                    }
            }
            .tabItem { Label("Accueil", systemImage: "heart.text.square") }

            NavigationStack {
                CompanionActivityView(viewModel: activityViewModel).navigationTitle("Activité")
            }
            .tabItem { Label("Activité", systemImage: "figure.walk") }

            NavigationStack {
                CompanionSleepView(viewModel: sleepViewModel).navigationTitle("Sommeil")
            }
            .tabItem { Label("Sommeil", systemImage: "moon.zzz.fill") }

            NavigationStack {
                CompanionTrainingView(viewModel: trainingViewModel, planViewModel: viewModel)
                    .navigationTitle("Entraînement")
            }
            .tabItem { Label("Entraînement", systemImage: "figure.run") }

            NavigationStack {
                CompanionBodyView().navigationTitle("Corps")
            }
            .tabItem { Label("Corps", systemImage: "figure") }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                CompanionSyncView(viewModel: viewModel)
                    .navigationTitle("Réglages")
                    .toolbar {
                        Button("Fermer") { showingSettings = false }
                    }
            }
        }
    }
}
