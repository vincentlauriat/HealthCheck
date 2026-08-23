import Foundation

/// Fusionne les réveils concurrents en une seule synchro en vol. Les 10
/// `HKObserverQuery` de `BackgroundSync` peuvent se déclencher en rafale ;
/// sans garde, chacune lance un `syncAll()` complet en parallèle. Un `actor`
/// sérialise naturellement l'entrée dans `run` : le premier appelant met
/// `isRunning` à `true` avant tout point de suspension, donc tout appel
/// concurrent voit forcément cet état à jour et repart sans exécuter `work`.
/// Un réveil ainsi abandonné n'est pas grave — la livraison est
/// at-least-once et le prochain réveil (ou le bouton manuel) rattrapera le
/// delta.
actor SyncCoalescer {
    private var isRunning = false

    func run(_ work: @Sendable () async -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        await work()
        isRunning = false
    }
}
