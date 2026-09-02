import Foundation

/// Assemble les entrées d'`InsightsEngine` à partir de ce que
/// `WellnessOrchestrator` a déjà agrégé et des résumés de période. Extrait de
/// `DashboardViewModel` pour que l'Accueil de l'iPhone produise les mêmes
/// observations — et surtout applique les mêmes garde-fous, comme le minimum
/// de trois nuits sans lequel une sieste isolée déclencherait une « dette de
/// sommeil ».
enum InsightInputsBuilder {
    static let minimumTrackedNights = 3

    static func build(wellness: WellnessOrchestrator.Result,
                      thisWeek: PeriodSummary?,
                      lastWeek: PeriodSummary?,
                      weightDelta30d: Double?,
                      calendar: Calendar,
                      today: Date) -> InsightInputs {
        var inputs = InsightInputs()
        guard let d7 = calendar.date(byAdding: .day, value: -7, to: today) else { return inputs }

        inputs.restingHRMean7 = mean(wellness.hrDaily.filter { $0.date >= d7 }.map(\.value))
        inputs.restingHRMean30 = mean(wellness.hrDaily.map(\.value))
        let recentNights = wellness.sleepNights.filter { $0.date >= d7 }
        inputs.sleepHoursMean7 = recentNights.count >= minimumTrackedNights
            ? mean(recentNights.map(\.value))
            : nil
        inputs.stepsThisWeek = thisWeek?.steps
        inputs.stepsLastWeek = lastWeek?.steps
        inputs.vo2Trend = wellness.vo2Trend
        inputs.weightDelta30d = weightDelta30d
        return inputs
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
