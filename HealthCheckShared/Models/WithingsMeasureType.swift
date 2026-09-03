import Foundation

/// Identifiants des mesures Withings sans équivalent HealthKit. Ils vivent
/// dans le partagé parce que `BodyViewModel` les lit en base et qu'il est
/// partagé depuis le SP5 ; le reste de `WithingsMapper` — l'appel `getmeas` et
/// sa conversion, qui dépendent des modèles de l'API — reste macOS.
///
/// Sur iPhone ces quatre séries sont toujours vides : rien ne les y écrit.
/// C'est voulu — l'écran Corps du Companion se limite au poids et à la masse
/// grasse, sans composition corporelle ni Sankey.
enum WithingsMeasureType {
    static let muscleMass = "WithingsMuscleMass"
    static let hydration = "WithingsHydration"
    static let boneMass = "WithingsBoneMass"
    static let visceralFat = "WithingsVisceralFat"
}
