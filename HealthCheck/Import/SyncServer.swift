import Foundation
import Network

enum SyncServerError: Error {
    case timedOut
}

/// Serveur de synchro compagnon : NWListener persistant sur un port
/// éphémère, annoncé en Bonjour. Chaque connexion accumule les octets
/// jusqu'à la longueur annoncée par les en-têtes, passe la requête au
/// routeur, répond, ferme. HTTP/1.1 « Connection: close » assumé.
final class SyncServer {
    private let router: CompanionRouter
    private let onInsert: (Int) -> Void
    private let onPair: () -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "healthcheck.syncserver")

    var port: UInt16? { listener?.port?.rawValue }

    init(router: CompanionRouter, onInsert: @escaping (Int) -> Void, onPair: @escaping () -> Void = {}) {
        self.router = router
        self.onInsert = onInsert
        self.onPair = onPair
    }

    func start() throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: "HealthCheck", type: CompanionProtocol.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        // `listener.port` vaut déjà non-nil (`.any`, rawValue 0) dès l'appel à
        // `start`, avant que l'OS n'ait attribué le vrai port éphémère — un
        // simple polling sur `port == nil` sort donc trop tôt. On attend le
        // véritable signal `.ready` du framework Network à la place.
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        let waitResult = semaphore.wait(timeout: .now() + 2)
        if let startError {
            self.listener = nil
            throw startError
        }
        if waitResult == .timedOut {
            // Ni `.ready` ni `.failed` reçu à temps : ne pas retourner un
            // serveur à moitié vivant avec un port potentiellement invalide.
            listener.cancel()
            self.listener = nil
            throw SyncServerError.timedOut
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let expected = SyncHTTPRequest.expectedTotalLength(buffer), buffer.count >= expected {
                self.respond(on: connection, requestData: buffer.prefix(expected))
            } else if isComplete || error != nil || buffer.count > (16 << 20) {
                connection.cancel() // requête incomplète, avortée ou aberrante
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, requestData: Data) {
        let result: (response: Data, insertedRows: Int, didPair: Bool)
        if let request = SyncHTTPRequest.parse(Data(requestData)) {
            result = router.handle(request)
        } else {
            result = (SyncHTTPResponse.make(status: 400), 0, false)
        }
        if result.insertedRows > 0 { onInsert(result.insertedRows) }
        if result.didPair { onPair() }
        connection.send(content: result.response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
