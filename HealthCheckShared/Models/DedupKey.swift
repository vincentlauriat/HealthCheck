import Foundation
import CryptoKit

/// Clé d'identité partagée par les trois modèles stockés (`HealthRecord`,
/// `Workout`, `SleepRecord`). Elle sert d'`id` en base, et c'est elle qui fait
/// tenir l'`INSERT OR IGNORE` : deux descriptions d'une même mesure doivent
/// produire la même clé, sinon la base garde les deux.
///
/// Les deux chemins d'ingestion décrivent pourtant la même mesure autrement :
///
/// | champ       | export XML d'Apple Santé            | synchro iPhone        |
/// |-------------|-------------------------------------|-----------------------|
/// | `startDate` | précision à la seconde              | millisecondes         |
/// | `value`     | arrondi                             | pleine précision      |
/// | `device`    | description `HKDevice` complète     | vide                  |
///
/// La clé normalise donc ces trois écarts : dates tronquées à la seconde,
/// valeurs à quatre décimales, `device` exclu — c'est une métadonnée sur
/// l'appareil, pas l'identité de la mesure. Sans cette normalisation, la base
/// du Mac comptait 31 409 lignes en double sur la fenêtre où les deux chemins
/// se recouvrent, ce qui biaisait toutes les moyennes calculées sur des
/// échantillons ponctuels — FC de repos, HRV, VO2max — car le résolveur de
/// priorité de source, lui, ne dédoublonne que les intervalles qui se
/// chevauchent.
enum DedupKey {
    /// ISO 8601 **sans** `.withFractionalSeconds` : la sous-seconde est
    /// simplement absente du texte formaté, donc tronquée.
    private static let secondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func second(_ date: Date) -> String {
        secondFormatter.string(from: date)
    }

    /// Quatre décimales, la précision de l'export XML. `String(format:)` sans
    /// locale utilise toujours le point décimal — le hachage ne dépend donc
    /// pas de la locale de l'appareil.
    static func rounded(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    static func digest(_ components: [String]) -> String {
        let digest = SHA256.hash(data: Data(components.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
