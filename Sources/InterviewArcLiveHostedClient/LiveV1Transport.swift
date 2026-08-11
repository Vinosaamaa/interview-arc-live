import Foundation

public enum LiveV1HTTPMethod: String, Codable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
}

public struct LiveV1Request: Sendable {
    public let method: LiveV1HTTPMethod
    public let path: String
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: LiveV1HTTPMethod,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct LiveV1HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol LiveV1Transport: Sendable {
    func send(_ request: LiveV1Request) async throws -> LiveV1HTTPResponse
}

public enum LiveV1ClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case transportUnavailable
    case malformedResponse
    case server(statusCode: Int, code: String, retryable: Bool)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Interview Arc Live has an invalid hosted-service configuration."
        case .transportUnavailable:
            "Interview Arc is temporarily unreachable. Local recovery data is unchanged."
        case .malformedResponse:
            "Interview Arc returned an incompatible response. Local recovery data is unchanged."
        case .server(_, let code, _):
            switch code {
            case "unauthorized": "Reconnect Interview Arc to continue."
            case "lease_held": "This activity is open in another writer."
            case "lease_conflict": "The activity writer lease changed. Refresh before continuing."
            case "revision_conflict": "The hosted activity changed. Refresh before continuing."
            case "candidate_evidence_required": "Finish needs one accepted candidate answer."
            case "result_required": "Choose and save a result before finishing."
            case "no_next_activity": "There is no later activity in this session."
            default: "Interview Arc rejected this action (\(code))."
            }
        }
    }

    public var code: String? {
        guard case .server(_, let code, _) = self else { return nil }
        return code
    }

    public var retryable: Bool {
        guard case .server(_, _, let retryable) = self else {
            return self == .transportUnavailable
        }
        return retryable
    }
}

public struct LiveV1Client: Sendable {
    private let tokenReader: any LiveIntegrationTokenReading
    private let transport: any LiveV1Transport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        tokenReader: any LiveIntegrationTokenReading,
        transport: any LiveV1Transport
    ) {
        self.tokenReader = tokenReader
        self.transport = transport
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func today() async throws -> LiveTodayProjection {
        let response: LiveTodayProjection = try await send(
            method: .get,
            path: "/live/v1/today"
        )
        guard response.protocolVersion == 1 else {
            throw LiveV1ClientError.malformedResponse
        }
        return response
    }

    public func activity(_ activityID: String) async throws -> LiveActivityProjection {
        let response: LiveActivityProjection = try await send(
            method: .get,
            path: "/live/v1/activities/\(try pathComponent(activityID))"
        )
        guard response.protocolVersion == 1,
              response.activity.id == activityID else {
            throw LiveV1ClientError.malformedResponse
        }
        return response
    }

    public func receipt(
        activityID: String,
        operationID: String
    ) async throws -> LiveMutationReceipt {
        let response: LiveReceiptResponse = try await send(
            method: .get,
            path: "/live/v1/activities/\(try pathComponent(activityID))/receipts/\(try pathComponent(operationID))"
        )
        guard response.protocolVersion == 1,
              response.receipt.protocolVersion == 1,
              response.receipt.activityId == activityID,
              response.receipt.operationId == operationID else {
            throw LiveV1ClientError.malformedResponse
        }
        return response.receipt
    }

    public func mutation<Body: Encodable & Sendable>(
        activityID: String,
        suffix: String,
        body: Body
    ) async throws -> LiveMutationResponse {
        let response: LiveMutationResponse = try await send(
            method: .post,
            path: "/live/v1/activities/\(try pathComponent(activityID))/\(suffix)",
            body: encoder.encode(body)
        )
        return try validate(response, activityID: activityID)
    }

    public func mutation(
        activityID: String,
        suffix: String,
        canonicalBody: Data
    ) async throws -> LiveMutationResponse {
        let response: LiveMutationResponse = try await send(
            method: .post,
            path: "/live/v1/activities/\(try pathComponent(activityID))/\(suffix)",
            body: canonicalBody
        )
        return try validate(response, activityID: activityID)
    }

    public func uploadClip(
        activityID: String,
        clipID: String,
        body: Data,
        headers: [String: String]
    ) async throws -> LiveMutationResponse {
        let response: LiveMutationResponse = try await send(
            method: .put,
            path: "/live/v1/activities/\(try pathComponent(activityID))/clips/\(try pathComponent(clipID))/content",
            body: body,
            additionalHeaders: headers
        )
        return try validate(response, activityID: activityID)
    }

    public func canonicalData<Body: Encodable>(_ body: Body) throws -> Data {
        try encoder.encode(body)
    }

    private func send<Response: Decodable>(
        method: LiveV1HTTPMethod,
        path: String,
        body: Data? = nil,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        let token: String
        do { token = try await tokenReader.readIntegrationToken() }
        catch { throw error }

        var headers = additionalHeaders
        headers["Authorization"] = "Bearer \(token)"
        headers["Accept"] = "application/json"
        if body != nil, headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }

        let response: LiveV1HTTPResponse
        do {
            response = try await transport.send(
                LiveV1Request(
                    method: method,
                    path: path,
                    headers: headers,
                    body: body
                )
            )
        } catch let error as LiveV1ClientError {
            throw error
        } catch {
            throw LiveV1ClientError.transportUnavailable
        }

        guard (200..<300).contains(response.statusCode) else {
            guard let error = try? decoder.decode(LiveErrorBody.self, from: response.body) else {
                throw LiveV1ClientError.malformedResponse
            }
            throw LiveV1ClientError.server(
                statusCode: response.statusCode,
                code: error.code,
                retryable: error.retryable
            )
        }
        do { return try decoder.decode(Response.self, from: response.body) }
        catch { throw LiveV1ClientError.malformedResponse }
    }

    private func pathComponent(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._:-")
        )
        guard !value.isEmpty,
              value.count <= 200,
              value.unicodeScalars.allSatisfy(allowed.contains),
              value.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) == true else {
            throw LiveV1ClientError.invalidConfiguration
        }
        return value
    }

    private func validate(
        _ response: LiveMutationResponse,
        activityID: String
    ) throws -> LiveMutationResponse {
        guard response.protocolVersion == 1,
              response.receipt.protocolVersion == 1,
              response.receipt.activityId == activityID,
              response.activity.protocolVersion == 1,
              response.activity.activity.id == activityID else {
            throw LiveV1ClientError.malformedResponse
        }
        return response
    }
}
