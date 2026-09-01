import SwiftUI

/// Shell de navigation à deux onglets : « Conseils » (autonome, calcule
/// localement, indépendant de l'appairage) et « Synchro » (appairage,
/// statut, plan d'entraînement — contenu historique de l'app, inchangé,
/// déplacé dans CompanionSyncView).
struct CompanionRootView: View {
    @ObservedObject var viewModel: CompanionViewModel
    @ObservedObject var advisorViewModel: CompanionAdvisorViewModel

    var body: some View {
        TabView {
            NavigationStack {
                CompanionAdvisorView(viewModel: advisorViewModel, lastSyncDate: viewModel.lastSyncDate)
                    .navigationTitle("Conseils")
            }
            .tabItem { Label("Conseils", systemImage: "heart.text.square") }

            CompanionSyncView(viewModel: viewModel)
                .tabItem { Label("Synchro", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}
