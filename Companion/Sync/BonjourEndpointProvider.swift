import Foundation
import Network
import os

/// Découverte du Mac : browse Bonjour `_healthcheck._tcp`, puis résolution
/// de l'endpoint via une connexion TCP éphémère (le chemin prêt expose
/// host/port). Chaque appel refait une découverte courte : le port du Mac
/// est éphémère et change à chaque lancement de l'app Mac.
final class BonjourEndpointProvider: MacEndpointProviding {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func currentEndpoint() async -> (host: String, port: UInt16)? {
        guard let service = await discoverService() else { return nil }
        return await resolve(service)
    }

    private func discoverService() async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: CompanionProtocol.serviceType, domain: nil),
                                    using: NWParameters.tcp)
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ endpoint: NWEndpoint?) {
                let first = hasResumed.withLock { resumed -> Bool in
                    if resumed { return false }
                    resumed = true
                    return true
                }
                guard first else { return }
                browser.cancel()
                continuation.resume(returning: endpoint)
            }
            browser.browseResultsChangedHandler = { results, _ in
                if let first = results.first { finish(first.endpoint) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish(nil) }
            }
            browser.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private func resolve(_ endpoint: NWEndpoint) async -> (host: String, port: UInt16)? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ result: (String, UInt16)?) {
                let first = hasResumed.withLock { resumed -> Bool in
                    if resumed { return false }
                    resumed = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        finish((Self.urlHost(for: host), port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Formate un `NWEndpoint.Host` pour interpolation directe dans un
    /// gabarit d'URL `http://\(host):\(port)`. Un littéral IPv6 sans
    /// crochets rend `URL(string:)` nil (RFC 3986 §3.2.2) ; le scope d'une
    /// adresse link-local (`%en0`) doit en plus être percent-encodé (`%25`)
    /// une fois à l'intérieur des crochets.
    static func urlHost(for host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            let raw = "\(address)"
            return raw.split(separator: "%").first.map(String.init) ?? raw
        case .ipv6(let address):
            let raw = "\(address)"
            if let percentIndex = raw.firstIndex(of: "%") {
                let addr = raw[raw.startIndex..<percentIndex]
                let iface = raw[raw.index(after: percentIndex)...]
                return "[\(addr)%25\(iface)]"
            }
            return "[\(raw)]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
