import SwiftUI
import Charts
import MapKit

struct WorkoutsView: View {
    @ObservedObject var viewModel: WorkoutsViewModel
    @State private var expandedWorkout: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                thisWeekRow

                if viewModel.weeklyVolumes.contains(where: { $0.totalMinutes > 0 }) {
                    volumeChart
                }

                if viewModel.recentWorkouts.isEmpty {
                    ContentUnavailableView(
                        "Aucune séance récente",
                        systemImage: "figure.run",
                        description: Text("Les séances enregistrées par l'Apple Watch apparaîtront ici après un import.")
                    )
                } else {
                    recentList
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if !viewModel.hasLoaded { try? viewModel.load() } }
    }

    private var thisWeekRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175, maximum: 260), spacing: 12)], spacing: 12) {
            MetricCard(
                style: MetricStyle(title: "Séances cette semaine", unit: "", systemImage: "figure.run", tint: .green),
                value: "\(viewModel.thisWeekCount)"
            )
            MetricCard(
                style: MetricStyle(title: "Durée", unit: "min", systemImage: "clock.fill", tint: .blue),
                value: viewModel.thisWeekMinutes.formatted(.number.precision(.fractionLength(0)))
            )
            MetricCard(
                style: MetricStyle(title: "Calories", unit: "kcal", systemImage: "flame.fill", tint: .red),
                value: viewModel.thisWeekKcal.formatted(.number.precision(.fractionLength(0)))
            )
        }
    }

    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume hebdomadaire — 12 semaines").font(.title2.bold())
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
            .frame(height: 220)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dernières séances").font(.title2.bold())
            VStack(spacing: 8) {
                ForEach(Array(viewModel.recentWorkouts.enumerated()), id: \.offset) { _, workout in
                    workoutRow(workout)
                }
            }
        }
    }

    @ViewBuilder
    private func workoutRow(_ workout: WorkoutItem) -> some View {
        VStack(spacing: 0) {
            workoutRowHeader(workout)
            if expandedWorkout == workout.startDate, let routeURL = workout.routeURL {
                RouteMapView(routeURL: routeURL)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4)))
    }

    @ViewBuilder
    private func workoutRowHeader(_ workout: WorkoutItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: WorkoutStatsEngine.icon(for: workout.label))
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 34, height: 34)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.label).font(.callout.weight(.semibold))
                Text(workout.startDate.formatted(
                    .dateTime.weekday(.wide).day().month(.wide).hour().minute()
                        .locale(Locale(identifier: "fr_FR"))
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                if let minutes = workout.minutes {
                    statText(minutes.formatted(.number.precision(.fractionLength(0))) + " min", icon: "clock")
                }
                if let distance = workout.distanceKm, distance > 0 {
                    statText(distance.formatted(.number.precision(.fractionLength(1))) + " km", icon: "location")
                }
                if let energy = workout.energyKcal, energy > 0 {
                    statText(energy.formatted(.number.precision(.fractionLength(0))) + " kcal", icon: "flame")
                }
                if let hr = workout.averageHeartRate {
                    statText(hr.formatted(.number.precision(.fractionLength(0))) + " bpm", icon: "heart")
                }
                if workout.routeURL != nil {
                    Image(systemName: expandedWorkout == workout.startDate ? "chevron.up" : "map")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard workout.routeURL != nil else { return }
            withAnimation(.snappy) {
                expandedWorkout = expandedWorkout == workout.startDate ? nil : workout.startDate
            }
        }
        .help(workout.routeURL != nil ? "Cliquer pour afficher la trace GPS" : "")
    }

    @ViewBuilder
    private func statText(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}

/// Carte de la trace GPS d'une séance : polyline sur fond standard, cadrage
/// automatique sur le contenu. Le GPX est chargé hors du MainActor.
struct RouteMapView: View {
    let routeURL: URL
    @State private var points: [RoutePoint] = []
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Trace illisible", systemImage: "map")
            } else if points.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
                    MapPolyline(coordinates: points.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                    .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .task(id: routeURL) {
            let url = routeURL
            let loaded = await Task.detached(priority: .userInitiated) { () -> [RoutePoint] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return GPXParser.points(from: data)
            }.value
            if loaded.isEmpty { failed = true } else { points = loaded }
        }
    }
}
