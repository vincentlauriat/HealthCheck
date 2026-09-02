import SwiftUI
import Charts

/// Sous-écran « Séances » de l'onglet Entraînement : le volume des douze
/// dernières semaines, puis les sorties récentes avec leurs chiffres et leurs
/// traces GPS — le tout lu localement, sans le Mac.
struct CompanionWorkoutsView: View {
    @ObservedObject var viewModel: WorkoutsViewModel
    @State private var expandedWorkout: Date?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if viewModel.recentWorkouts.isEmpty {
                    ContentUnavailableView(
                        "Aucune séance",
                        systemImage: "figure.run",
                        description: Text("Vos sorties enregistrées par la montre apparaîtront ici.")
                    )
                    .padding(.top, 40)
                } else {
                    weekCard
                    if viewModel.weeklyVolumes.contains(where: { $0.totalMinutes > 0 }) {
                        volumeChart
                    }
                    ForEach(viewModel.recentWorkouts, id: \.startDate) { workout in
                        workoutCard(workout)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
        .refreshable { try? viewModel.load() }
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cette semaine", systemImage: "calendar")
                .font(.headline)
            Text("\(viewModel.thisWeekCount) séance\(viewModel.thisWeekCount > 1 ? "s" : "") · \(Int(viewModel.thisWeekMinutes.rounded())) min · \(Int(viewModel.thisWeekKcal.rounded())) kcal")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume hebdomadaire — 12 semaines")
                .font(.headline)
            Chart {
                ForEach(viewModel.weeklyVolumes, id: \.weekStart) { week in
                    ForEach(week.minutesByActivity.sorted(by: { $0.key < $1.key }), id: \.key) { activity, minutes in
                        BarMark(
                            x: .value("Semaine", week.weekStart, unit: .weekOfYear),
                            y: .value("Minutes", minutes)
                        )
                        .foregroundStyle(by: .value("Activité", activity))
                    }
                }
            }
            .frame(height: 200)
            .chartLegend(position: .bottom, spacing: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func workoutCard(_ workout: WorkoutItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workout.label).font(.headline)
            Text(workout.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Chaque valeur n'apparaît que si elle existe : une séance sans
            // distance ni FC n'affiche pas de zéro fabriqué.
            HStack(spacing: 12) {
                if let minutes = workout.minutes {
                    Text("\(Int(minutes.rounded())) min")
                }
                if let km = workout.distanceKm {
                    Text("\(km.formatted(.number.precision(.fractionLength(1)))) km")
                }
                if let kcal = workout.energyKcal {
                    Text("\(Int(kcal.rounded())) kcal")
                }
                if let hr = workout.averageHeartRate {
                    Text("\(Int(hr.rounded())) bpm")
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)

            if let routeURL = workout.routeURL {
                Button {
                    expandedWorkout = expandedWorkout == workout.startDate ? nil : workout.startDate
                } label: {
                    Label(expandedWorkout == workout.startDate ? "Masquer la trace" : "Trace GPS",
                          systemImage: "map")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                if expandedWorkout == workout.startDate {
                    CompanionRouteMapView(routeURL: routeURL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
