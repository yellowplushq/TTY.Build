import Foundation

/// The phone-issued pairing code embedded in the desktop install command.
/// Same unified ceremony as the desktop's code, with client-issuer defaults:
/// one hour of validity, multi-use within that window, and a durable private
/// key that survives code refreshes so claims sealed under an earlier code
/// stay acceptable. Every claim of this code is host-initiated and therefore
/// waits for the user's explicit accept — the confirmation card.
public struct ReversePairingToken: Codable, Equatable, Sendable {
    public let code: PairingCode
    public let privateKey: Data
    public let expiresAt: Int64

    public init(code: PairingCode, privateKey: Data, expiresAt: Int64) {
        self.code = code
        self.privateKey = privateKey
        self.expiresAt = expiresAt
    }

    public func isUsable(at date: Date = Date(), margin: TimeInterval = 60) -> Bool {
        Int64(date.timeIntervalSince1970 + margin) < expiresAt
    }
}

/// One computer's sealed, host-initiated claim awaiting the user's accept.
public struct ReversePairingClaim: Equatable, Sendable {
    public let claimID: String
    public let computerID: String
    public let computerName: String
    public let hostPublicKey: Data
    public let encryptedSecret: Data
    public let createdAt: Int64

    public init(
        claimID: String,
        computerID: String,
        computerName: String,
        hostPublicKey: Data,
        encryptedSecret: Data,
        createdAt: Int64
    ) {
        self.claimID = claimID
        self.computerID = computerID
        self.computerName = computerName
        self.hostPublicKey = hostPublicKey
        self.encryptedSecret = encryptedSecret
        self.createdAt = createdAt
    }
}

extension PedalsServiceAPI {
    private struct RegisterClientCodeRequest: Encodable {
        let publicKey: String
    }

    private struct RegisterClientCodeResponse: Decodable {
        let code: String
        let expiresAt: Int64
    }

    private struct HostClaimRequest: Encodable {
        let code: String
        let publicKey: String
        let computerName: String
    }

    private struct HostClaimResponse: Decodable {
        let claimId: String
        let clientPublicKey: String
    }

    private struct PendingClaimsResponse: Decodable {
        struct Claim: Decodable {
            let claimId: String
            let computerId: String
            let computerName: String
            let hostPublicKey: String
            let encryptedSecret: String
            let createdAt: Int64
        }

        let claims: [Claim]
    }

    /// Issues (or refreshes) the client's code. Pass the stored private key
    /// when refreshing an expired code: keeping the key stable keeps claims
    /// sealed under earlier codes acceptable (the service only drops pending
    /// claims when the key rotates). The private key never leaves the
    /// device; callers persist the returned token in the Keychain.
    public func registerReversePairingToken(
        as client: ClientIdentity,
        reusingPrivateKey: Data? = nil
    ) async throws -> ReversePairingToken {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let privateKey = reusingPrivateKey ?? PairingKeyAgreement.makePrivateKey()
        let publicKey = try PairingKeyAgreement.publicKey(for: privateKey)
        let response: RegisterClientCodeResponse = try await send(
            method: "POST",
            path: "/v2/clients/me/pairing-codes",
            bearer: client.clientToken,
            body: RegisterClientCodeRequest(
                publicKey: publicKey.base64URLEncodedString()
            )
        )
        return try ReversePairingToken(
            code: PairingCode(response.code),
            privateKey: privateKey,
            expiresAt: response.expiresAt
        )
    }

    /// Computer side: claims the phone's code, seals this computer's E2EE
    /// secret to the phone's durable public key, and submits the envelope.
    /// Fire-and-forget — the binding edge appears only after the user
    /// accepts on the phone, which this computer never observes.
    public func claimReversePairing(
        code: PairingCode,
        computerName: String,
        identity: HostIdentity
    ) async throws {
        guard identity.computer.serviceURL == serviceURL else {
            throw APIError.serviceMismatch
        }
        let privateKey = PairingKeyAgreement.makePrivateKey()
        let publicKey = try PairingKeyAgreement.publicKey(for: privateKey)
        let name = String(computerName.filter { !$0.isNewline }.prefix(64))
        let claim: HostClaimResponse = try await send(
            method: "POST",
            path: "/v2/computers/\(identity.computer.computerID)/pairing-codes/claim",
            bearer: identity.hostToken,
            body: HostClaimRequest(
                code: code.digits,
                publicKey: publicKey.base64URLEncodedString(),
                computerName: name.isEmpty ? "Mac" : name
            )
        )
        guard let clientPublicKey = Data(base64URLEncoded: claim.clientPublicKey),
              clientPublicKey.count == 32
        else { throw APIError.invalidResponse }
        let envelope = try PairingKeyAgreement.seal(
            secret: identity.computer.secret,
            hostPrivateKey: privateKey,
            clientPublicKey: clientPublicKey,
            claimID: claim.claimId
        )
        let _: EmptyResponse = try await send(
            method: "POST",
            path: "/v2/computers/\(identity.computer.computerID)/pairing-claims/\(claim.claimId)/complete",
            bearer: identity.hostToken,
            body: CompletePairingClaimRequest(
                encryptedSecret: envelope.base64URLEncodedString()
            )
        )
    }

    /// Sealed host-initiated claims awaiting the user's accept.
    public func reversePairingClaims(
        as client: ClientIdentity
    ) async throws -> [ReversePairingClaim] {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let response: PendingClaimsResponse = try await send(
            method: "GET",
            path: "/v2/clients/me/pairing-claims",
            bearer: client.clientToken
        )
        return try response.claims.map { claim in
            guard let hostPublicKey = Data(base64URLEncoded: claim.hostPublicKey),
                  hostPublicKey.count == 32,
                  let envelope = Data(base64URLEncoded: claim.encryptedSecret)
            else { throw APIError.invalidResponse }
            return ReversePairingClaim(
                claimID: claim.claimId,
                computerID: claim.computerId,
                computerName: claim.computerName,
                hostPublicKey: hostPublicKey,
                encryptedSecret: envelope,
                createdAt: claim.createdAt
            )
        }
    }

    /// Decrypts a claim envelope with the durable token key. Pure local
    /// crypto — callers persist the binding in the Keychain BEFORE calling
    /// `confirmReversePairingClaim`, so a concurrent binding reconcile can
    /// never delete the freshly created edge.
    public func openReversePairingClaim(
        _ claim: ReversePairingClaim,
        token: ReversePairingToken
    ) throws -> ComputerBinding {
        let secret = try PairingKeyAgreement.open(
            envelope: claim.encryptedSecret,
            clientPrivateKey: token.privateKey,
            hostPublicKey: claim.hostPublicKey,
            claimID: claim.claimID
        )
        guard secret.count == ComputerBinding.secretByteCount else {
            throw APIError.invalidResponse
        }
        return try ComputerBinding(
            serviceURL: serviceURL,
            computerID: claim.computerID,
            secret: secret
        )
    }

    /// The user's accept: atomically creates the binding edge.
    public func confirmReversePairingClaim(
        claimID: String,
        as client: ClientIdentity
    ) async throws {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let _: EmptyResponse = try await send(
            method: "POST",
            path: "/v2/clients/me/pairing-claims/\(claimID)/accept",
            bearer: client.clientToken
        )
    }

    /// Rejects a claim. The computer is never told.
    public func rejectReversePairingClaim(
        claimID: String,
        as client: ClientIdentity
    ) async throws {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "/v2/clients/me/pairing-claims/\(claimID)",
            bearer: client.clientToken
        )
    }
}
