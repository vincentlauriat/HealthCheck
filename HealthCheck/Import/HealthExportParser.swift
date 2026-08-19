import Foundation

final class HealthExportParser: NSObject, XMLParserDelegate {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var onRecord: ((HealthRecord) -> Void) = { _ in }
    private var onWorkout: ((Workout) -> Void) = { _ in }
    private var onSleepRecord: ((SleepRecord) -> Void) = { _ in }
    private var parseError: Error?

    private var currentWorkoutAttributes: [String: String]?
    private var currentWorkoutRouteFileName: String?

    func parse(
        fileURL: URL,
        onRecord: @escaping (HealthRecord) -> Void,
        onWorkout: @escaping (Workout) -> Void,
        onSleepRecord: @escaping (SleepRecord) -> Void = { _ in }
    ) throws {
        self.onRecord = onRecord
        self.onWorkout = onWorkout
        self.onSleepRecord = onSleepRecord
        self.parseError = nil

        guard let stream = InputStream(url: fileURL) else {
            throw HealthExportParserError.cannotOpenFile(fileURL)
        }
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.shouldProcessNamespaces = false

        if !parser.parse() {
            throw parseError ?? parser.parserError ?? HealthExportParserError.unknown
        }
    }

    private func date(from attributes: [String: String], key: String) -> Date? {
        attributes[key].flatMap { Self.dateFormatter.date(from: $0) }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Record":
            if attributeDict["type"] == "HKCategoryTypeIdentifierSleepAnalysis" {
                guard
                    let type = attributeDict["type"],
                    let sourceName = attributeDict["sourceName"],
                    let value = attributeDict["value"],
                    let startDate = date(from: attributeDict, key: "startDate"),
                    let endDate = date(from: attributeDict, key: "endDate")
                else {
                    return
                }
                onSleepRecord(SleepRecord(
                    type: type,
                    sourceName: sourceName,
                    device: attributeDict["device"],
                    value: value,
                    startDate: startDate,
                    endDate: endDate,
                    creationDate: date(from: attributeDict, key: "creationDate")
                ))
                return
            }
            guard
                let type = attributeDict["type"],
                let sourceName = attributeDict["sourceName"],
                let valueString = attributeDict["value"],
                let value = Double(valueString),
                let startDate = date(from: attributeDict, key: "startDate"),
                let endDate = date(from: attributeDict, key: "endDate")
            else {
                return // unknown/malformed record shape — skip, never fatal
            }
            let record = HealthRecord(
                type: type,
                sourceName: sourceName,
                device: attributeDict["device"],
                unit: attributeDict["unit"],
                value: value,
                startDate: startDate,
                endDate: endDate,
                creationDate: date(from: attributeDict, key: "creationDate")
            )
            onRecord(record)

        case "Workout":
            currentWorkoutAttributes = attributeDict
            currentWorkoutRouteFileName = nil

        case "FileReference":
            if currentWorkoutAttributes != nil, let path = attributeDict["path"] {
                currentWorkoutRouteFileName = (path as NSString).lastPathComponent
            }

        default:
            break // unknown element — ignored, parsing continues
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard elementName == "Workout", let attributes = currentWorkoutAttributes else { return }
        defer {
            currentWorkoutAttributes = nil
            currentWorkoutRouteFileName = nil
        }

        guard
            let activityType = attributes["workoutActivityType"],
            let sourceName = attributes["sourceName"],
            let durationString = attributes["duration"],
            let duration = Double(durationString),
            let startDate = date(from: attributes, key: "startDate"),
            let endDate = date(from: attributes, key: "endDate")
        else {
            return
        }

        let workout = Workout(
            activityType: activityType,
            sourceName: sourceName,
            duration: duration,
            durationUnit: attributes["durationUnit"] ?? "",
            totalDistance: attributes["totalDistance"].flatMap(Double.init),
            totalDistanceUnit: attributes["totalDistanceUnit"],
            totalEnergyBurned: attributes["totalEnergyBurned"].flatMap(Double.init),
            totalEnergyBurnedUnit: attributes["totalEnergyBurnedUnit"],
            startDate: startDate,
            endDate: endDate,
            routeFileName: currentWorkoutRouteFileName
        )
        onWorkout(workout)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

enum HealthExportParserError: Error {
    case cannotOpenFile(URL)
    case unknown
}
