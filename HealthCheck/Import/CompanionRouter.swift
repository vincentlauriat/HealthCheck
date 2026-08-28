import Foundation

/// Routage pur des requêtes du serveur compagnon : requête parsée →
/// réponse HTTP + nombre de lignes insérées. Aucun réseau ici — tout
/// se teste sur des valeurs.
struct CompanionRouter {
    let pairing: PairingManager
    let tokenStore: CompanionTokenStore
    let importer: CompanionImporter
    let appVersion: String
    var trainingPlanProvider: (() throws -> TrainingPlanResponse)? = nil

    func handle(_ request: SyncHTTPRequest) -> (response: Data, insertedRows: Int, didPair: Bool) {
        switch (request.method, request.path) {
        case ("POST", CompanionProtocol.pairPath):
            let (response, didPair) = handlePair(request)
            return (response, 0, didPair)
        case ("POST", CompanionProtocol.batchPath):
            let (response, inserted) = handleBatch(request)
            return (response, inserted, false)
        case ("GET", CompanionProtocol.statusPath):
            return (handleStatus(request), 0, false)
        case ("GET", CompanionProtocol.trainingPlanPath):
            return (handleTrainingPlan(request), 0, false)
        default:
            return (SyncHTTPResponse.make(status: 404), 0, false)
        }
    }

    private func handlePair(_ request: SyncHTTPRequest) -> (Data, Bool) {
        guard let pair = try? ExchangeCoding.decoder.decode(PairRequest.self, from: request.body)
        else { return (SyncHTTPResponse.make(status: 400), false) }
        guard let token = pairing.redeem(code: pair.code)
        else { return (SyncHTTPResponse.make(status: 401), false) }
        let body = try? ExchangeCoding.encoder.encode(PairResponse(token: token))
        return (SyncHTTPResponse.make(status: 200, json: body), true)
    }

    private func authorized(_ request: SyncHTTPRequest) -> Bool {
        guard let expected = tokenStore.currentToken(), let provided = request.bearerToken
        else { return false }
        return provided == expected
    }

    private func handleBatch(_ request: SyncHTTPRequest) -> (Data, Int) {
        guard authorized(request) else { return (SyncHTTPResponse.make(status: 401), 0) }
        guard let batch = try? ExchangeCoding.decoder.decode(ExchangeBatch.self, from: request.body)
        else { return (SyncHTTPResponse.make(status: 400), 0) }
        do {
            let inserted = try importer.ingest(batch)
            let body = try? ExchangeCoding.encoder.encode(BatchResponse(inserted: inserted))
            return (SyncHTTPResponse.make(status: 200, json: body), inserted)
        } catch {
            return (SyncHTTPResponse.make(status: 500), 0)
        }
    }

    private func handleStatus(_ request: SyncHTTPRequest) -> Data {
        guard authorized(request) else { return SyncHTTPResponse.make(status: 401) }
        let body = try? ExchangeCoding.encoder.encode(StatusResponse(app: "HealthCheck", version: appVersion))
        return SyncHTTPResponse.make(status: 200, json: body)
    }

    private func handleTrainingPlan(_ request: SyncHTTPRequest) -> Data {
        guard authorized(request) else { return SyncHTTPResponse.make(status: 401) }
        do {
            let response = try trainingPlanProvider?() ?? TrainingPlanResponse(
                generatedAt: Date(),
                goal: nil,
                weeks: [],
                message: "Aucun objectif de course actif. Créez un objectif sur le Mac pour afficher un plan ici."
            )
            let body = try? ExchangeCoding.encoder.encode(response)
            return SyncHTTPResponse.make(status: 200, json: body)
        } catch {
            return SyncHTTPResponse.make(status: 500)
        }
    }
}
