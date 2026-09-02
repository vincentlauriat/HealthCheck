import SwiftUI
import MapKit

/// Trace GPS d'une séance, lue depuis le fichier GPX local. Équivalent iOS de
/// `RouteMapView` (macOS) : même parseur partagé, sans le `.help()` qui
/// n'existe pas sur iPhone.
struct CompanionRouteMapView: View {
    let routeURL: URL
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var parsed = false

    var body: some View {
        Group {
            if !points.isEmpty {
                Map(initialPosition: .automatic, interactionModes: [.zoom, .pan]) {
                    MapPolyline(coordinates: points)
                        .stroke(.orange, lineWidth: 3)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Trace GPS de la séance")
            } else if parsed {
                Text("Trace illisible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: routeURL) {
            let url = routeURL
            // Le parsing XML sort du MainActor : les GPX d'une sortie longue
            // font quelques centaines de Ko. La conversion en
            // `CLLocationCoordinate2D`, elle, reste ici — le type n'est pas
            // `Sendable` et ne peut pas franchir la frontière.
            let raw = await Task.detached(priority: .userInitiated) { () -> [RoutePoint] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                return GPXParser.points(from: data)
            }.value
            points = raw.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            parsed = true
        }
    }
}
