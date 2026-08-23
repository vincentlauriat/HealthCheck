import Foundation
import os

enum MacClientError: Error, Equatable {
    case unreachable        // Mac introuvable sur le réseau — rien de perdu, on réessaiera
    case unauthorized       // jeton refusé → état « appairage requis »
    case pairingRejected    // fenêtre fermée, code faux ou grillé
    case serverError(Int)
    case badResponse
}

/// Fournit l'adresse actuelle du Mac. L'implémentation Bonjour vit dans la
/// couche vive (Task 6) ; les tests injectent un endpoint fixe.
protocol MacEndpointProviding {
    func currentEndpoint() async -> (host: String, port: UInt16)?
}

/// Client HTTP du récepteur Mac. Trois requêtes, sémantique d'erreur alignée
/// sur le tableau §9 de la spec : toute non-2xx laisse l'appelant décider
/// (les ancres n'avancent jamais sur un échec).
final class MacClient {
    /// Endpoint résolu, mémorisé pour la durée de vie du client (typiquement
    /// une synchro) et invalidé dès qu'une requête échoue avec
    /// `.unreachable` — la découverte Bonjour n'a alors lieu qu'une fois par
    /// tentative de synchro dans le cas nominal, au lieu d'une fois par
    /// requête HTTP (jusqu'à ~86 découvertes sur la première synchro).
    private struct EndpointCache {
        var endpoint: (host: String, port: UInt16)?
        var resolved = false
    }

    private let endpointProvider: MacEndpointProviding
    private let tokenStore: KeychainTokenStore
    private let session: URLSession
    private let endpointCache = OSAllocatedUnfairLock(initialState: EndpointCache())

    init(endpointProvider: MacEndpointProviding, tokenStore: KeychainTokenStore, session: URLSession = .shared) {
        self.endpointProvider = endpointProvider
        self.tokenStore = tokenStore
        self.session = session
    }

    private func resolvedEndpoint() async -> (host: String, port: UInt16)? {
        let cached = endpointCache.withLock { $0 }
        if cached.resolved { return cached.endpoint }
        let endpoint = await endpointProvider.currentEndpoint()
        endpointCache.withLock { $0 = EndpointCache(endpoint: endpoint, resolved: true) }
        return endpoint
    }

    private func invalidateEndpoint() {
        endpointCache.withLock { $0 = EndpointCache() }
    }

    func pair(code: String) async throws {
        let body = try ExchangeCoding.encoder.encode(PairRequest(code: code))
        let (data, status) = try await send(path: CompanionProtocol.pairPath, method: "POST", body: body, authenticated: false)
        guard status == 200 else { throw status == 401 ? MacClientError.pairingRejected : MacClientError.serverError(status) }
        guard let payload = try? ExchangeCoding.decoder.decode(PairResponse.self, from: data) else {
            throw MacClientError.badResponse
        }
        try tokenStore.save(token: payload.token)
    }

    func push(batch: ExchangeBatch) async throws -> Int {
        let body = try ExchangeCoding.encoder.encode(batch)
        let (data, status) = try await send(path: CompanionProtocol.batchPath, method: "POST", body: body, authenticated: true)
        switch status {
        case 200:
            guard let payload = try? ExchangeCoding.decoder.decode(BatchResponse.self, from: data) else {
                throw MacClientError.badResponse
            }
            return payload.inserted
        case 401: throw MacClientError.unauthorized
        default: throw MacClientError.serverError(status)
        }
    }

    func status() async throws -> StatusResponse {
        let (data, status) = try await send(path: CompanionProtocol.statusPath, method: "GET", body: nil, authenticated: true)
        switch status {
        case 200:
            guard let payload = try? ExchangeCoding.decoder.decode(StatusResponse.self, from: data) else {
                throw MacClientError.badResponse
            }
            return payload
        case 401: throw MacClientError.unauthorized
        default: throw MacClientError.serverError(status)
        }
    }

    private func send(path: String, method: String, body: Data?, authenticated: Bool) async throws -> (Data, Int) {
        guard let endpoint = await resolvedEndpoint(),
              let url = URL(string: "http://\(endpoint.host):\(endpoint.port)\(path)")
        else {
            invalidateEndpoint()
            throw MacClientError.unreachable
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        if authenticated {
            // Un trousseau illisible n'est pas une requête non-authentifiée :
            // mieux vaut échouer proprement (`.unauthorized`) que d'envoyer
            // au Mac une requête sans jeton qu'il rejettera de toute façon
            // en 401, ce qui ferait perdre un jeton pourtant valide côté VM.
            guard let token = tokenStore.currentToken() else { throw MacClientError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            invalidateEndpoint() // adresse mémorisée possiblement périmée : refaire une découverte au prochain appel
            throw MacClientError.unreachable // Mac éteint / réseau différent : cas normal, pas fatal
        }
    }
}

extension MacClient: BatchPushing {}
