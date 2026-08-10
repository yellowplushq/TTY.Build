import Foundation

/// Typed v2 control-plane client shared by the desktop daemon and iOS app.
/// Terminal frames never pass through this API.
public final class TTYBuildServiceAPI: @unchecked Sendable {
    public static let productionServiceURL = URL(string: "https://tty.build")!

    public enum APIError: Error, LocalizedError, CustomStringConvertible, Equatable {
        case invalidResponse
        case rejected(status: Int, message: String)
        case serviceMismatch

        public var description: String {
            switch self {
            case .invalidResponse:
                "invalid response from TTY.Build service"
            case .rejected(let status, let message):
                "TTY.Build service rejected the request (HTTP \(status)): \(message)"
            case .serviceMismatch:
                "pairing request belongs to a different TTY.Build service"
            }
        }

        public var errorDescription: String? { description }
    }

    private struct CreateComputerResponse: Decodable {
        let computerId: String
        let hostToken: String
    }

    private struct CreateClientResponse: Decodable {
        let clientId: String
        let clientToken: String
        let statusToken: String
    }

    private struct ReconcileBindingsRequest: Encodable {
        let computerIds: [String]
    }

    private struct ReconcileBindingsResponse: Decodable {
        let computerIds: [String]
    }

    private struct SynchronizeDelegatedBindingsRequest: Encodable {
        let clientId: String
        let clientToken: String
    }

    private struct SynchronizeDelegatedBindingsResponse: Decodable {
        let bindingCount: Int
    }

    private struct CreatePairingCodeRequest: Encodable {
        let publicKey: String
        let ttlSeconds: Int?
        let singleUse: Bool?
    }

    private struct CreatePairingCodeResponse: Decodable {
        let codeId: String
        let code: String
        let expiresAt: Int64
        let singleUse: Bool
    }

    private struct HostPairingCodeStatusResponse: Decodable {
        let status: String
        let expiresAt: Int64
        let claimId: String?
        let clientPublicKey: String?
    }

    struct CompletePairingClaimRequest: Encodable {
        let encryptedSecret: String
    }

    private struct ClaimPairingCodeRequest: Encodable {
        let code: String
        let publicKey: String
    }

    private struct ClaimPairingCodeResponse: Decodable {
        let claimId: String
        let computerId: String
        let hostPublicKey: String
        let expiresAt: Int64
    }

    private struct ClientPairingClaimStatusResponse: Decodable {
        let status: String
        let computerId: String
        let expiresAt: Int64
        let encryptedSecret: String?
    }

    let serviceURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder

    public init(serviceURL: URL, session: URLSession = .shared) {
        self.serviceURL = serviceURL
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Registers a new computer and generates its independent E2EE secret.
    public func createComputer() async throws -> HostIdentity {
        let response: CreateComputerResponse = try await send(
            method: "POST", path: "/v2/computers"
        )
        let binding = try ComputerBinding(
            serviceURL: serviceURL,
            computerID: response.computerId,
            secret: SecureRandom.data(count: ComputerBinding.secretByteCount)
        )
        return HostIdentity(computer: binding, hostToken: response.hostToken)
    }

    /// Issues a pairing code for this computer. TTL and single-use are
    /// creation parameters of the unified ceremony; the desktop pairing page
    /// uses the defaults (15 minutes, single-use).
    public func createPairingCode(
        identity: HostIdentity,
        ttlSeconds: Int? = nil,
        singleUse: Bool? = nil
    ) async throws -> HostPairingCode {
        guard identity.computer.serviceURL == serviceURL else {
            throw APIError.serviceMismatch
        }
        let privateKey = PairingKeyAgreement.makePrivateKey()
        let publicKey = try PairingKeyAgreement.publicKey(for: privateKey)
        let response: CreatePairingCodeResponse = try await send(
            method: "POST",
            path: "/v2/computers/\(identity.computer.computerID)/pairing-codes",
            bearer: identity.hostToken,
            body: CreatePairingCodeRequest(
                publicKey: publicKey.base64URLEncodedString(),
                ttlSeconds: ttlSeconds,
                singleUse: singleUse
            )
        )
        return try HostPairingCode(
            codeID: response.codeId,
            code: PairingCode(response.code),
            expiresAt: response.expiresAt,
            privateKey: privateKey
        )
    }

    public func pairingCodeStatus(
        _ pairing: HostPairingCode,
        identity: HostIdentity
    ) async throws -> HostPairingCodeStatus {
        guard identity.computer.serviceURL == serviceURL else {
            throw APIError.serviceMismatch
        }
        let response: HostPairingCodeStatusResponse = try await send(
            method: "GET",
            path: "/v2/computers/\(identity.computer.computerID)/pairing-codes/\(pairing.codeID)",
            bearer: identity.hostToken
        )
        switch response.status {
        case "waiting":
            return .waiting
        case "claimed":
            guard let claimID = response.claimId,
                  let encoded = response.clientPublicKey,
                  let key = Data(base64URLEncoded: encoded), key.count == 32
            else { throw APIError.invalidResponse }
            return .claimed(claimID: claimID, clientPublicKey: key)
        case "completed":
            return .completed
        default:
            throw APIError.invalidResponse
        }
    }

    /// Seals this computer's E2EE secret onto a claim of its code.
    public func completePairingClaim(
        claimID: String,
        clientPublicKey: Data,
        privateKey: Data,
        identity: HostIdentity
    ) async throws {
        guard identity.computer.serviceURL == serviceURL else {
            throw APIError.serviceMismatch
        }
        let envelope = try PairingKeyAgreement.seal(
            secret: identity.computer.secret,
            hostPrivateKey: privateKey,
            clientPublicKey: clientPublicKey,
            claimID: claimID
        )
        let _: EmptyResponse = try await send(
            method: "POST",
            path: "/v2/computers/\(identity.computer.computerID)/pairing-claims/\(claimID)/complete",
            bearer: identity.hostToken,
            body: CompletePairingClaimRequest(
                encryptedSecret: envelope.base64URLEncodedString()
            )
        )
    }

    public func cancelPairingCode(
        _ pairing: HostPairingCode,
        identity: HostIdentity
    ) async throws {
        guard identity.computer.serviceURL == serviceURL else {
            throw APIError.serviceMismatch
        }
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "/v2/computers/\(identity.computer.computerID)/pairing-codes/\(pairing.codeID)",
            bearer: identity.hostToken
        )
    }

    /// The interactive client flow: claim the computer's code, wait for the
    /// sealed envelope, decrypt, and accept. The accept is the ceremony's
    /// only edge-creating step; a claim the client itself initiated is
    /// accepted without further ceremony — typing the code was the consent.
    public func pair(code: PairingCode, as client: ClientIdentity) async throws -> ComputerBinding {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let privateKey = PairingKeyAgreement.makePrivateKey()
        let publicKey = try PairingKeyAgreement.publicKey(for: privateKey)
        let response: ClaimPairingCodeResponse = try await send(
            method: "POST",
            path: "/v2/clients/me/pairing-codes/claim",
            bearer: client.clientToken,
            body: ClaimPairingCodeRequest(
                code: code.digits,
                publicKey: publicKey.base64URLEncodedString()
            )
        )
        guard let hostPublicKey = Data(base64URLEncoded: response.hostPublicKey),
              hostPublicKey.count == 32
        else { throw APIError.invalidResponse }

        while Int64(Date().timeIntervalSince1970) < response.expiresAt {
            try Task.checkCancellation()
            let status: ClientPairingClaimStatusResponse = try await send(
                method: "GET",
                path: "/v2/clients/me/pairing-claims/\(response.claimId)",
                bearer: client.clientToken
            )
            if status.status == "sealed",
               let encodedEnvelope = status.encryptedSecret,
               let envelope = Data(base64URLEncoded: encodedEnvelope)
            {
                let secret = try PairingKeyAgreement.open(
                    envelope: envelope,
                    clientPrivateKey: privateKey,
                    hostPublicKey: hostPublicKey,
                    claimID: response.claimId
                )
                guard secret.count == ComputerBinding.secretByteCount else {
                    throw APIError.invalidResponse
                }
                let binding = try ComputerBinding(
                    serviceURL: serviceURL,
                    computerID: response.computerId,
                    secret: secret
                )
                let _: EmptyResponse = try await send(
                    method: "POST",
                    path: "/v2/clients/me/pairing-claims/\(response.claimId)/accept",
                    bearer: client.clientToken
                )
                return binding
            }
            guard status.status == "waiting" else { throw APIError.invalidResponse }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw APIError.rejected(status: 410, message: "pairing code expired")
    }

    public func deleteComputer(identity: HostIdentity) async throws {
        guard identity.computer.serviceURL == serviceURL else {
            throw APIError.serviceMismatch
        }
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "/v2/computers/\(identity.computer.computerID)",
            bearer: identity.hostToken
        )
    }

    public func createClient() async throws -> ClientIdentity {
        let response: CreateClientResponse = try await send(
            method: "POST", path: "/v2/clients"
        )
        return try ClientIdentity(
            serviceURL: serviceURL,
            clientID: response.clientId,
            clientToken: response.clientToken,
            statusToken: response.statusToken
        )
    }

    /// Declares the client's authoritative binding set. The service converges
    /// by deleting its own edges (and the delegated Watch's) that are absent
    /// from the list; it never creates an edge, so pairing remains the only
    /// way to add one. Returns the server-side set after convergence.
    @discardableResult
    public func reconcileBindings(
        computerIDs: [String],
        as client: ClientIdentity
    ) async throws -> [String] {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let response: ReconcileBindingsResponse = try await send(
            method: "PUT",
            path: "/v2/clients/me/bindings",
            bearer: client.clientToken,
            body: ReconcileBindingsRequest(computerIds: computerIDs)
        )
        return response.computerIds
    }

    /// Makes a second client principal (for example, a paired Watch) inherit
    /// exactly the source client's current server-side computer bindings.
    /// E2EE computer secrets are never sent to the service by this operation.
    @discardableResult
    public func synchronizeBindings(
        from source: ClientIdentity,
        to delegate: ClientIdentity
    ) async throws -> Int {
        guard source.serviceURL == serviceURL,
              delegate.serviceURL == serviceURL,
              source.clientID != delegate.clientID
        else { throw APIError.serviceMismatch }
        let response: SynchronizeDelegatedBindingsResponse = try await send(
            method: "PUT",
            path: "/v2/clients/me/delegated-bindings",
            bearer: source.clientToken,
            body: SynchronizeDelegatedBindingsRequest(
                clientId: delegate.clientID,
                clientToken: delegate.clientToken
            )
        )
        return response.bindingCount
    }

    struct EmptyResponse: Decodable {}

    func send<Response: Decodable>(
        method: String,
        path: String,
        bearer: String? = nil
    ) async throws -> Response {
        try await send(method: method, path: path, bearer: bearer, encodedBody: nil)
    }

    func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: String,
        bearer: String? = nil,
        body: Body
    ) async throws -> Response {
        try await send(
            method: method,
            path: path,
            bearer: bearer,
            encodedBody: try encoder.encode(body)
        )
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        bearer: String?,
        encodedBody: Data?
    ) async throws -> Response {
        var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw APIError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let encodedBody {
            request.httpBody = encodedBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data).error.message)
                ?? String(data: data.prefix(1_024), encoding: .utf8)
                ?? "request failed"
            throw APIError.rejected(status: http.statusCode, message: message)
        }
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}
