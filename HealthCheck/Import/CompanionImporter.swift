import Foundation

/// Ingestion d'un batch compagnon dans le store existant. L'idempotence
/// vient des clés synthétiques + `INSERT OR IGNORE` : re-livrer un batch
/// coûte zéro insertion, exactement comme réimporter un zip.
struct CompanionImporter {
    let store: HealthStore
    let routeStore: RouteStore

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Retourne le nombre total de lignes réellement insérées.
    func ingest(_ batch: ExchangeBatch) throws -> Int {
        var inserted = 0

        inserted += try store.insertRecords(batch.records.map {
            HealthRecord(type: $0.type, sourceName: $0.sourceName, device: $0.device,
                         unit: $0.unit, value: $0.value,
                         startDate: $0.startDate, endDate: $0.endDate, creationDate: $0.creationDate)
        })

        inserted += try store.insertSleepRecords(batch.sleep.map {
            SleepRecord(type: $0.type, sourceName: $0.sourceName, device: $0.device,
                        value: $0.value,
                        startDate: $0.startDate, endDate: $0.endDate, creationDate: $0.creationDate)
        })

        // GPX écrit avant la ligne workout (même ordre que le pipeline zip) ;
        // routeFileName stocké toujours quand routePoints non-vide (self-healing) :
        // échec d'écriture → nom stocké mais fichier absent → RouteStore.url retourne nil ;
        // relivraison réussie → même nom déterministe → fichier créé → url(forRouteFileName:) résout.
        let workouts = batch.workouts.map { exchange -> Workout in
            var routeFileName: String?
            if let points = exchange.routePoints, !points.isEmpty {
                let rawName = Self.routeFileName(for: exchange)
                let name = (rawName as NSString).lastPathComponent
                _ = try? writeGPX(points: points, fileName: name)
                routeFileName = name
            }
            return Workout(activityType: exchange.activityType, sourceName: exchange.sourceName,
                           duration: exchange.duration, durationUnit: exchange.durationUnit,
                           totalDistance: exchange.totalDistance, totalDistanceUnit: exchange.totalDistanceUnit,
                           totalEnergyBurned: exchange.totalEnergyBurned, totalEnergyBurnedUnit: exchange.totalEnergyBurnedUnit,
                           startDate: exchange.startDate, endDate: exchange.endDate,
                           routeFileName: routeFileName)
        }
        inserted += try store.insertWorkouts(workouts)
        return inserted
    }

    /// Nom déterministe : re-livrer la même séance réécrit le même fichier.
    static func routeFileName(for workout: ExchangeWorkout) -> String {
        let stamp = isoFormatter.string(from: workout.startDate)
            .replacingOccurrences(of: ":", with: "-")
        return "companion_\(stamp)_\(workout.activityType).gpx"
    }

    private func writeGPX(points: [ExchangeRoutePoint], fileName: String) throws {
        try FileManager.default.createDirectory(at: routeStore.directory, withIntermediateDirectories: true)
        var gpx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        gpx += "<gpx version=\"1.1\" creator=\"HealthCheck Companion\"><trk><trkseg>\n"
        for p in points {
            gpx += "<trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><time>\(Self.isoFormatter.string(from: p.timestamp))</time></trkpt>\n"
        }
        gpx += "</trkseg></trk></gpx>\n"
        let target = routeStore.directory.appendingPathComponent((fileName as NSString).lastPathComponent)
        try Data(gpx.utf8).write(to: target, options: .atomic)
    }
}
