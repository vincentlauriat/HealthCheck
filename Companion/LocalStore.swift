import Foundation

/// Store HealthKit local à l'iPhone, alimenté directement par les lectures
/// HealthKit déjà effectuées par HealthKitReaderLive — indépendant du Mac.
/// Spec: docs/superpowers/specs/2026-08-28-shared-analysis-foundation-design.md §5.
struct LocalStore {
    let healthStore: HealthStore
    let routeStore: RouteStore
    let importer: CompanionImporter

    init(applicationSupportDirectory: URL? = nil) throws {
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        healthStore = try HealthStore(path: base.appendingPathComponent("health.sqlite").path)
        routeStore = RouteStore(directory: base.appendingPathComponent("routes", isDirectory: true))
        importer = CompanionImporter(store: healthStore, routeStore: routeStore)
    }
}

/// Repli quand LocalStore ne peut pas s'ouvrir (ex: disque plein) : le push
/// vers le Mac continue, seule l'autonomie locale est perdue pour cette
/// session — spec §8, "ne doit pas régresser la synchro Mac existante".
struct NoOpImporter: LocalIngesting {
    func ingest(_ batch: ExchangeBatch) throws -> Int { 0 }
}
