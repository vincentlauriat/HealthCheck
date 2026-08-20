import Foundation

/// Point d'une trace GPS — découplé de MapKit pour rester testable.
struct RoutePoint: Equatable {
    let latitude: Double
    let longitude: Double
}

/// Parseur GPX minimal : ne lit que les `<trkpt lat="…" lon="…">` des
/// segments de trace. Les fichiers d'export Apple font quelques centaines
/// de Ko — un passage SAX suffit largement.
final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [RoutePoint] = []

    static func points(from data: Data) -> [RoutePoint] {
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        guard elementName == "trkpt",
              let lat = attributes["lat"].flatMap(Double.init),
              let lon = attributes["lon"].flatMap(Double.init)
        else { return }
        points.append(RoutePoint(latitude: lat, longitude: lon))
    }
}

/// Dossier persistant des traces GPX, alimenté à chaque import de zip.
/// Les fichiers sont adressés par leur nom (`route_2026-08-18_1.gpx`),
/// tel que stocké dans `workout.routeFileName`.
struct RouteStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HealthCheck", isDirectory: true)
                .appendingPathComponent("routes", isDirectory: true)
    }

    /// URL du fichier de trace s'il est présent localement. Le nom est réduit
    /// à son dernier composant : jamais de traversée de chemin possible.
    func url(forRouteFileName name: String) -> URL? {
        let base = (name as NSString).lastPathComponent
        guard !base.isEmpty else { return nil }
        let url = directory.appendingPathComponent(base)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copie tous les `.gpx` trouvés sous `extractedDirectory` (récursif) vers
    /// le dossier persistant. Retourne le nombre de fichiers copiés
    /// (les existants sont remplacés — l'export le plus récent fait foi).
    @discardableResult
    func importRoutes(from extractedDirectory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(at: extractedDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var copied = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "gpx" {
            let target = directory.appendingPathComponent(fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: fileURL, to: target)
            copied += 1
        }
        return copied
    }
}
