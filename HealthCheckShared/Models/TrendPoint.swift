import Foundation

struct TrendPoint: Equatable {
    let date: Date
    let value: Double
    /// Combien d'échantillons ont produit cette valeur. `nil` quand la notion
    /// n'a pas de sens (une nuit de sommeil) ou qu'elle n'est pas connue.
    ///
    /// Ce n'est pas une statistique décorative : la valeur « du jour » est la
    /// moyenne des seuls échantillons **connus à cet instant**. Une journée
    /// vue à une mesure et la même journée vue à neuf ne donnent pas le même
    /// score de forme — 57,0 contre 95,4 sur le 2026-09-02.
    let sampleCount: Int?

    init(date: Date, value: Double, sampleCount: Int? = nil) {
        self.date = date
        self.value = value
        self.sampleCount = sampleCount
    }
}
