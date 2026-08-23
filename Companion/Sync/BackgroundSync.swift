import Foundation
import HealthKit
import os
import os.log

/// Réveil automatique : une HKObserverQuery par type + background delivery.
/// Fréquences : .immediate pour les quotidiens (sommeil, FC repos, HRV,
/// VO₂), .hourly pour les flux denses (pas, distance, énergie, exercice,
/// FC). Le réveil est opportuniste — iOS ne garantit aucun horaire ; le
/// bouton manuel reste le recours (spec §12).
enum BackgroundSync {
    private static let hourlyTypes: [HKQuantityTypeIdentifier] = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .appleExerciseTime, .heartRate
    ]
    private static let immediateTypes: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max
    ]
    /// Un seul enregistrement d'observateurs par process : un re-run du
    /// `.task` de la vue racine (ex. changement de scène SwiftUI) ne doit
    /// pas enregistrer une seconde fois les mêmes `HKObserverQuery`, ce qui
    /// multiplierait les réveils pour un même changement HealthKit.
    private static let registered = OSAllocatedUnfairLock(initialState: false)

    static func register(store: HKHealthStore, onWake: @escaping () async -> Void) {
        let alreadyRegistered = registered.withLock { flag -> Bool in
            defer { flag = true }
            return flag
        }
        guard !alreadyRegistered else { return }

        var configs: [(HKSampleType, HKUpdateFrequency)] =
            hourlyTypes.map { (HKQuantityType($0), .hourly) } +
            immediateTypes.map { (HKQuantityType($0), .immediate) }
        configs.append((HKCategoryType(.sleepAnalysis), .immediate))
        configs.append((HKObjectType.workoutType(), .immediate))

        for (type, frequency) in configs {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                if let error {
                    os_log(.error, "Observer %{public}@ : %{public}@", type.identifier, "\(error)")
                    completion()
                    return
                }
                Task {
                    await onWake()
                    completion() // ack APRÈS la tentative de synchro : iOS re-livre sinon
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: frequency) { granted, error in
                if let error { os_log(.error, "BG delivery %{public}@ : %{public}@", type.identifier, "\(error)") }
                else if !granted { os_log(.info, "BG delivery refusé pour %{public}@", type.identifier) }
            }
        }
    }
}
