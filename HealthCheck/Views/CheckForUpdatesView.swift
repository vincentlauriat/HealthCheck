import Combine
import Sparkle
import SwiftUI

/// Sparkle désactive la recherche de mises à jour pendant qu'une session est
/// déjà en cours ; `canCheckForUpdates` est observable en KVO et c'est le seul
/// signal fiable pour griser l'entrée de menu. On le republie en `@Published`.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// Entrée « Rechercher les mises à jour… » du menu de l'application.
struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Rechercher les mises à jour…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
