import Foundation

struct ImportSummary {
    let recordsSeen: Int
    let recordsInserted: Int
    let workoutsSeen: Int
    let workoutsInserted: Int
    let sleepRecordsSeen: Int
    let sleepRecordsInserted: Int
}

enum HealthExportImporterError: Error {
    case exportFileNotFound(URL)
}

final class HealthExportImporter {
    private let store: HealthStore
    private let extractor: ZipExtractor
    private let batchSize: Int

    init(store: HealthStore, extractor: ZipExtractor = ZipExtractor(), batchSize: Int = 5000) {
        self.store = store
        self.extractor = extractor
        self.batchSize = batchSize
    }

    func importZip(at url: URL, progress: @escaping (Int) -> Void) throws -> ImportSummary {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthCheckImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        try extractor.extract(zipURL: url, to: workDir)

        let exportURL = try locateExportXML(under: workDir)
        // Les traces GPX sont copiées vers un dossier persistant avant le
        // nettoyage du répertoire temporaire — l'écran Séances les lit ensuite
        // par leur routeFileName.
        try RouteStore().importRoutes(from: workDir)

        var recordsSeen = 0
        var recordsInserted = 0
        var workoutsSeen = 0
        var workoutsInserted = 0
        var sleepRecordsSeen = 0
        var sleepRecordsInserted = 0
        var recordBuffer: [HealthRecord] = []
        var workoutBuffer: [Workout] = []
        var sleepRecordBuffer: [SleepRecord] = []
        var flushError: Error?

        func flushRecords() throws {
            guard !recordBuffer.isEmpty else { return }
            recordsInserted += try store.insertRecords(recordBuffer)
            recordBuffer.removeAll(keepingCapacity: true)
        }
        func flushWorkouts() throws {
            guard !workoutBuffer.isEmpty else { return }
            workoutsInserted += try store.insertWorkouts(workoutBuffer)
            workoutBuffer.removeAll(keepingCapacity: true)
        }
        func flushSleepRecords() throws {
            guard !sleepRecordBuffer.isEmpty else { return }
            sleepRecordsInserted += try store.insertSleepRecords(sleepRecordBuffer)
            sleepRecordBuffer.removeAll(keepingCapacity: true)
        }

        try HealthExportParser().parse(
            fileURL: exportURL,
            onRecord: { record in
                recordBuffer.append(record)
                recordsSeen += 1
                progress(recordsSeen + workoutsSeen + sleepRecordsSeen)
                if recordBuffer.count >= self.batchSize {
                    do { try flushRecords() } catch { flushError = flushError ?? error }
                }
            },
            onWorkout: { workout in
                workoutBuffer.append(workout)
                workoutsSeen += 1
                progress(recordsSeen + workoutsSeen + sleepRecordsSeen)
                if workoutBuffer.count >= self.batchSize {
                    do { try flushWorkouts() } catch { flushError = flushError ?? error }
                }
            },
            onSleepRecord: { sleepRecord in
                sleepRecordBuffer.append(sleepRecord)
                sleepRecordsSeen += 1
                progress(recordsSeen + workoutsSeen + sleepRecordsSeen)
                if sleepRecordBuffer.count >= self.batchSize {
                    do { try flushSleepRecords() } catch { flushError = flushError ?? error }
                }
            }
        )

        if let flushError { throw flushError }

        try flushRecords()
        try flushWorkouts()
        try flushSleepRecords()

        return ImportSummary(
            recordsSeen: recordsSeen,
            recordsInserted: recordsInserted,
            workoutsSeen: workoutsSeen,
            workoutsInserted: workoutsInserted,
            sleepRecordsSeen: sleepRecordsSeen,
            sleepRecordsInserted: sleepRecordsInserted
        )
    }

    private func locateExportXML(under directory: URL) throws -> URL {
        let candidate = directory.appendingPathComponent("export.xml")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }

        // Apple Health zips a top-level "apple_health_export/" folder in some export flows.
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "export.xml" {
                return fileURL
            }
        }
        throw HealthExportImporterError.exportFileNotFound(directory)
    }
}
