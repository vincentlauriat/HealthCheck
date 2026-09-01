import Foundation
import HealthKit

/// Ancres HKQueryAnchor persistées par type, une par fichier. Le store est
/// volontairement bête : c'est `SyncEngine` qui décide QUAND sauver (jamais
/// avant l'ack complet du delta — livraison at-least-once, spec §5/§7).
struct AnchorStore {
    /// Ancres du push vers le Mac.
    static let macSubdirectory = "anchors"
    /// Ancres de l'ingestion locale, strictement distinctes : elles avancent
    /// dès l'insertion réussie sur l'iPhone, sans rien attendre du Mac. Les
    /// partager reviendrait à conditionner l'autonomie de l'iPhone à
    /// l'appairage, et priverait à jamais la base locale de l'historique déjà
    /// consommé par les synchros antérieures à son existence.
    static let localSubdirectory = "anchors-local"

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Self.macSubdirectory, isDirectory: true)
    }

    init(subdirectory: String) {
        self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    private func fileURL(for typeIdentifier: String) -> URL {
        directory.appendingPathComponent("\((typeIdentifier as NSString).lastPathComponent).anchor")
    }

    func anchor(for typeIdentifier: String) -> HKQueryAnchor? {
        guard let data = try? Data(contentsOf: fileURL(for: typeIdentifier)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func save(_ anchor: HKQueryAnchor, for typeIdentifier: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        try data.write(to: fileURL(for: typeIdentifier), options: .atomic)
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
