import Foundation
import HealthKit

/// Conversion HKSample → format d'échange, avec les unités EXACTES que la
/// base du Mac contient déjà (relevées sur la base réelle, spec §4). Le Mac
/// ingère sans aucune conversion. `device` est toujours nil (ruling dédup) ;
/// `sourceName` est le nom HealthKit verbatim — même chaîne que l'export
/// zip, donc mêmes clés synthétiques et même résolution de priorité.
enum HKMapper {
    static let quantityUnits: [String: (unit: HKUnit, label: String)] = [
        HKQuantityTypeIdentifier.stepCount.rawValue: (.count(), "count"),
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue: (.meterUnit(with: .kilo), "km"),
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: (.kilocalorie(), "kcal"),
        HKQuantityTypeIdentifier.appleExerciseTime.rawValue: (.minute(), "min"),
        HKQuantityTypeIdentifier.heartRate.rawValue: (HKUnit.count().unitDivided(by: .minute()), "count/min"),
        HKQuantityTypeIdentifier.restingHeartRate.rawValue: (HKUnit.count().unitDivided(by: .minute()), "count/min"),
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: (.secondUnit(with: .milli), "ms"),
        HKQuantityTypeIdentifier.vo2Max.rawValue: (
            HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())),
            "mL/min·kg"
        ),
        // SP5 — lus pour l'écran Corps de l'iPhone, jamais poussés vers le Mac
        // (`SyncEngine.localOnlyTypes`). Libellés et échelles alignés sur ce
        // que la base contient déjà : `unit` entre dans `DedupKey`, et le taux
        // de graisse y est une fraction (0,25), pas un pourcentage (25).
        HKQuantityTypeIdentifier.bodyMass.rawValue: (.gramUnit(with: .kilo), "kg"),
        HKQuantityTypeIdentifier.bodyFatPercentage.rawValue: (.percent(), "%"),
        HKQuantityTypeIdentifier.leanBodyMass.rawValue: (.gramUnit(with: .kilo), "kg")
    ]

    static func record(from sample: HKQuantitySample) -> ExchangeRecord? {
        guard let mapping = quantityUnits[sample.quantityType.identifier] else { return nil }
        return ExchangeRecord(
            type: sample.quantityType.identifier,
            sourceName: sample.sourceRevision.source.name,
            device: nil,
            unit: mapping.label,
            value: sample.quantity.doubleValue(for: mapping.unit),
            startDate: sample.startDate,
            endDate: sample.endDate,
            creationDate: nil
        )
    }

    private static let sleepValues: [Int: String] = [
        HKCategoryValueSleepAnalysis.inBed.rawValue: "HKCategoryValueSleepAnalysisInBed",
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: "HKCategoryValueSleepAnalysisAsleepUnspecified",
        HKCategoryValueSleepAnalysis.awake.rawValue: "HKCategoryValueSleepAnalysisAwake",
        HKCategoryValueSleepAnalysis.asleepCore.rawValue: "HKCategoryValueSleepAnalysisAsleepCore",
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue: "HKCategoryValueSleepAnalysisAsleepDeep",
        HKCategoryValueSleepAnalysis.asleepREM.rawValue: "HKCategoryValueSleepAnalysisAsleepREM"
    ]

    static func sleep(from sample: HKCategorySample) -> ExchangeSleep? {
        guard sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
              // Défensif : le lookup du dictionnaire protège contre des valeurs inconnues.
              // HealthKit valide déjà les rawValue à la construction, rendant ce cas
              // inaccessible via l'API publique aujourd'hui, mais forward-compatible si
              // une nouvelle HKCategoryValueSleepAnalysis est ajoutée.
              let phase = sleepValues[sample.value] else { return nil }
        return ExchangeSleep(
            type: "HKCategoryTypeIdentifierSleepAnalysis",
            sourceName: sample.sourceRevision.source.name,
            device: nil,
            value: phase,
            startDate: sample.startDate,
            endDate: sample.endDate,
            creationDate: nil
        )
    }

    /// Types couverts : tout ce que la base réelle contient aujourd'hui,
    /// plus les libellés du Mac. Hors table → Other (le Mac affiche
    /// « Autre » et le moteur de stats fonctionne normalement).
    private static let activityNames: [HKWorkoutActivityType: String] = [
        .walking: "HKWorkoutActivityTypeWalking",
        .running: "HKWorkoutActivityTypeRunning",
        .hiking: "HKWorkoutActivityTypeHiking",
        .cycling: "HKWorkoutActivityTypeCycling",
        .swimming: "HKWorkoutActivityTypeSwimming",
        .highIntensityIntervalTraining: "HKWorkoutActivityTypeHighIntensityIntervalTraining",
        .functionalStrengthTraining: "HKWorkoutActivityTypeFunctionalStrengthTraining",
        .traditionalStrengthTraining: "HKWorkoutActivityTypeTraditionalStrengthTraining",
        .rowing: "HKWorkoutActivityTypeRowing",
        .mixedCardio: "HKWorkoutActivityTypeMixedCardio",
        .underwaterDiving: "HKWorkoutActivityTypeUnderwaterDiving",
        .snowSports: "HKWorkoutActivityTypeSnowSports",
        .downhillSkiing: "HKWorkoutActivityTypeDownhillSkiing",
        .elliptical: "HKWorkoutActivityTypeElliptical",
        .yoga: "HKWorkoutActivityTypeYoga",
        .coreTraining: "HKWorkoutActivityTypeCoreTraining",
        .cooldown: "HKWorkoutActivityTypeCooldown",
        .stairClimbing: "HKWorkoutActivityTypeStairClimbing",
        .tennis: "HKWorkoutActivityTypeTennis",
        .racquetball: "HKWorkoutActivityTypeRacquetball",
        .pilates: "HKWorkoutActivityTypePilates",
        .soccer: "HKWorkoutActivityTypeSoccer",
        .swimBikeRun: "HKWorkoutActivityTypeSwimBikeRun"
    ]

    static func activityTypeName(_ type: HKWorkoutActivityType) -> String {
        activityNames[type] ?? "HKWorkoutActivityTypeOther"
    }

    static func workout(from workout: HKWorkout, routePoints: [ExchangeRoutePoint]?) -> ExchangeWorkout {
        // API statistics(for:) (non dépréciée) avec repli sur les distances
        // spécifiques à l'activité ; l'énergie active est toujours le même type.
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie())
        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceSwimming, .distanceCycling]
        let distanceKm = distanceTypes.lazy
            .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity() }
            .map { $0.doubleValue(for: .meterUnit(with: .kilo)) }
            .first(where: { $0 > 0 })

        return ExchangeWorkout(
            activityType: activityTypeName(workout.workoutActivityType),
            sourceName: workout.sourceRevision.source.name,
            duration: workout.duration / 60.0,
            durationUnit: "min",
            totalDistance: distanceKm,
            totalDistanceUnit: distanceKm != nil ? "km" : nil,
            totalEnergyBurned: energy,
            totalEnergyBurnedUnit: energy != nil ? "kcal" : nil,
            startDate: workout.startDate,
            endDate: workout.endDate,
            routePoints: routePoints
        )
    }
}
