import XCTest
@testable import HealthCheck

final class GPXParserTests: XCTestCase {
    func test_points_extractsTrackpointCoordinates() {
        let gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Apple Health Export">
          <trk><trkseg>
            <trkpt lon="2.3522" lat="48.8566"><ele>35.0</ele><time>2026-08-16T17:16:00Z</time></trkpt>
            <trkpt lon="2.3530" lat="48.8570"><ele>36.2</ele></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let points = GPXParser.points(from: Data(gpx.utf8))

        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0], RoutePoint(latitude: 48.8566, longitude: 2.3522))
        XCTAssertEqual(points[1].latitude, 48.857, accuracy: 0.0001)
    }

    func test_points_returnsEmptyOnGarbage() {
        XCTAssertTrue(GPXParser.points(from: Data("pas du xml".utf8)).isEmpty)
    }
}

final class RouteStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RouteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    func test_importRoutes_copiesGpxFilesRecursively() throws {
        let source = tempDir.appendingPathComponent("extracted/apple_health_export/workout-routes", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("<gpx/>".utf8).write(to: source.appendingPathComponent("route_a.gpx"))
        try Data("pas une route".utf8).write(to: source.appendingPathComponent("export.xml"))

        let store = RouteStore(directory: tempDir.appendingPathComponent("routes", isDirectory: true))
        let copied = try store.importRoutes(from: tempDir.appendingPathComponent("extracted"))

        XCTAssertEqual(copied, 1, "seuls les .gpx sont copiés")
        XCTAssertNotNil(store.url(forRouteFileName: "route_a.gpx"))
        XCTAssertNotNil(store.url(forRouteFileName: "/workout-routes/route_a.gpx"),
                        "le nom est réduit à son dernier composant")
        XCTAssertNil(store.url(forRouteFileName: "route_absente.gpx"))
    }

    func test_url_neverEscapesDirectory() throws {
        let store = RouteStore(directory: tempDir)
        XCTAssertNil(store.url(forRouteFileName: "../../../etc/hosts"),
                     "un nom avec traversée de chemin est réduit à 'hosts', absent du dossier")
    }
}
