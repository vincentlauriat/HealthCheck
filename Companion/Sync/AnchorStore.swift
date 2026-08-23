import Foundation
import HealthKit

/// Ancres HKQueryAnchor persistées par type, une par fichier. Le store est
/// volontairement bête : c'est `SyncEngine` qui décide QUAND sauver (jamais
/// avant l'ack complet du delta — livraison at-least-once, spec §5/§7).
struct AnchorStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("anchors", isDirectory: true)
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
