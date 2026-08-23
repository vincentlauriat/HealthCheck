import Foundation

/// Parsing HTTP/1.1 minimaliste pour le serveur de synchro compagnon.
/// Même philosophie que `WithingsClient.parseCallback` : des fonctions
/// pures sur des octets, testables sans réseau.
struct SyncHTTPRequest {
    let method: String
    let path: String
    let bearerToken: String?
    let body: Data

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Longueur totale attendue (en-têtes + corps) dès que les en-têtes
    /// sont complets ; `nil` tant qu'on n'a pas vu CRLFCRLF. Le serveur
    /// accumule les octets d'une connexion jusqu'à cette longueur.
    static func expectedTotalLength(_ data: Data) -> Int? {
        guard let headerRange = data.range(of: headerTerminator) else { return nil }
        let headerData = data[data.startIndex..<headerRange.upperBound]
        guard let head = String(data: headerData, encoding: .utf8) else { return nil }
        let contentLength = head
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
            ?? 0
        return headerData.count + contentLength
    }

    static func parse(_ data: Data) -> SyncHTTPRequest? {
        guard let headerRange = data.range(of: headerTerminator),
              let head = String(data: data[data.startIndex..<headerRange.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else { return nil }

        var token: String?
        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "authorization", value.hasPrefix("Bearer ") {
                token = String(value.dropFirst("Bearer ".count))
            } else if name == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        let bodyStart = headerRange.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: min(contentLength, available))]
        return SyncHTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            bearerToken: token,
            body: Data(body)
        )
    }
}

enum SyncHTTPResponse {
    private static let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized",
                                  404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error"]

    static func make(status: Int, json: Data? = nil) -> Data {
        let body = json ?? Data()
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
