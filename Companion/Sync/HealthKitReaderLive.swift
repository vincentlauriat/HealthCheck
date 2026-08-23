import Foundation
import HealthKit
import CoreLocation

/// Lecture incrémentale réelle : une HKAnchoredObjectQuery par type.
/// Première synchro bornée à `initialWindowDays` par prédicat — sans lui,
/// la première ancre renverrait TOUT l'historique (piège documenté, spec §7).
final class HealthKitReaderLive: DeltaReading {
    static let initialWindowDays = 30

    private let store: HKHealthStore
    private let now: () -> Date

    init(store: HKHealthStore = HKHealthStore(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>(HKMapper.quantityUnits.keys.map {
            HKQuantityType(HKQuantityTypeIdentifier(rawValue: $0))
        })
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        return types
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    private func sampleType(for typeIdentifier: String) -> HKSampleType {
        switch typeIdentifier {
        case "sleep": return HKCategoryType(.sleepAnalysis)
        case "workouts": return HKObjectType.workoutType()
        default: return HKQuantityType(HKQuantityTypeIdentifier(rawValue: typeIdentifier))
        }
    }

    func delta(for typeIdentifier: String, since anchor: HKQueryAnchor?) async throws -> TypeDelta {
        let type = sampleType(for: typeIdentifier)
        // Prédicat de première synchro seulement ; ensuite l'ancre fait foi.
        let predicate: NSPredicate? = anchor == nil
            ? HKQuery.predicateForSamples(
                withStart: Calendar.current.date(byAdding: .day, value: -Self.initialWindowDays, to: now()),
                end: nil)
            : nil

        let (samples, newAnchor) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([HKSample], HKQueryAnchor), Error>) in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                              limit: HKObjectQueryNoLimit) { _, samples, _, newAnchor, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples ?? [], newAnchor ?? HKQueryAnchor(fromValue: 0)))
            }
            store.execute(query)
        }

        switch typeIdentifier {
        case "sleep":
            let mapped = samples.compactMap { ($0 as? HKCategorySample).flatMap(HKMapper.sleep(from:)) }
            return TypeDelta(typeIdentifier: typeIdentifier, records: [], sleep: mapped, workouts: [], newAnchor: newAnchor)
        case "workouts":
            var workouts: [ExchangeWorkout] = []
            for case let workout as HKWorkout in samples {
                let points = try? await routePoints(for: workout)
                workouts.append(HKMapper.workout(from: workout, routePoints: points))
            }
            return TypeDelta(typeIdentifier: typeIdentifier, records: [], sleep: [], workouts: workouts, newAnchor: newAnchor)
        default:
            let mapped = samples.compactMap { ($0 as? HKQuantitySample).flatMap(HKMapper.record(from:)) }
            return TypeDelta(typeIdentifier: typeIdentifier, records: mapped, sleep: [], workouts: [], newAnchor: newAnchor)
        }
    }

    /// Trace GPS d'une séance : route(s) associées puis flux de positions.
    private func routePoints(for workout: HKWorkout) async throws -> [ExchangeRoutePoint]? {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard let route = routes.first else { return nil }

        var points: [ExchangeRoutePoint] = []
        for try await locations in routeLocations(route) {
            points.append(contentsOf: locations.map {
                ExchangeRoutePoint(latitude: $0.coordinate.latitude,
                                   longitude: $0.coordinate.longitude,
                                   timestamp: $0.timestamp)
            })
        }
        return points.isEmpty ? nil : points
    }

    private func routeLocations(_ route: HKWorkoutRoute) -> AsyncThrowingStream<[CLLocation], Error> {
        AsyncThrowingStream { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { continuation.finish(throwing: error); return }
                if let locations { continuation.yield(locations) }
                if done { continuation.finish() }
            }
            store.execute(query)
        }
    }
}
