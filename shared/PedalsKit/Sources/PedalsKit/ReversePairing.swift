import Foundation

/// Phone-issued enrollment credential embedded in the desktop install
/// command. Unlike a forward pairing code it is long-lived and multi-use:
/// the private key is durable so a computer can claim and seal while the
/// phone app is not running. Each claimed computer still requires an
/// explicit confirmation on the phone before a binding edge exists.
public struct ReversePairingToken: Codable, Equatable, Sendable {
    public let code: PairingCode
    public let privateKey: Data

    public init(code: PairingCode, privateKey: Data) {
        self.code = code
        self.privateKey = privateKey
    }
}

/// One computer's completed claim against the phone's enrollment token,
/// waiting for the user to confirm it on the phone.
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
    private struct RegisterReverseTokenRequest: Encodable {
        let clientPublicKey: String
    }

    private struct RegisterReverseTokenResponse: Decodable {
        let code: String
    }

    private struct ClaimReversePairingRequest: Encodable {
        let code: String
        let hostPublicKey: String
        let computerName: String
    }

    private struct ClaimReversePairingResponse: Decodable {
        let claimId: String
        let clientPublicKey: String
    }

    private struct CompleteReverseClaimRequest: Encodable {
        let encryptedSecret: String
    }

    private struct ReverseClaimsResponse: Decodable {
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

    /// Registers (or replaces) the client's enrollment token. The durable
    /// private key never leaves the device; callers persist the returned
    /// token in the Keychain.
    public func registerReversePairingToken(
        as client: ClientIdentity
    ) async throws -> ReversePairingToken {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let privateKey = PairingKeyAgreement.makePrivateKey()
        let publicKey = try PairingKeyAgreement.publicKey(for: privateKey)
        let response: RegisterReverseTokenResponse = try await send(
            method: "PUT",
            path: "/v2/clients/me/reverse-pairing-token",
            bearer: client.clientToken,
            body: RegisterReverseTokenRequest(
                clientPublicKey: publicKey.base64URLEncodedString()
            )
        )
        return try ReversePairingToken(
            code: PairingCode(response.code),
            privateKey: privateKey
        )
    }

    /// Computer side: claims the phone's enrollment token, seals this
    /// computer's E2EE secret to the phone's durable public key, and submits
    /// the envelope. Fire-and-forget — the binding edge appears only after
    /// the user confirms on the phone, which this computer never observes.
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
        let claim: ClaimReversePairingResponse = try await send(
            method: "POST",
            path: "/v2/computers/\(identity.computer.computerID)/reverse-pairing-claims",
            bearer: identity.hostToken,
            body: ClaimReversePairingRequest(
                code: code.digits,
                hostPublicKey: publicKey.base64URLEncodedString(),
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
            sessionID: claim.claimId,
            salt: PairingKeyAgreement.reverseSalt
        )
        let _: EmptyResponse = try await send(
            method: "POST",
            path: "/v2/computers/\(identity.computer.computerID)/reverse-pairing-claims/\(claim.claimId)/complete",
            bearer: identity.hostToken,
            body: CompleteReverseClaimRequest(
                encryptedSecret: envelope.base64URLEncodedString()
            )
        )
    }

    /// Lists completed claims awaiting the user's confirmation on the phone.
    public func reversePairingClaims(
        as client: ClientIdentity
    ) async throws -> [ReversePairingClaim] {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let response: ReverseClaimsResponse = try await send(
            method: "GET",
            path: "/v2/clients/me/reverse-pairing-claims",
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
            sessionID: claim.claimID,
            salt: PairingKeyAgreement.reverseSalt
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

    /// Confirms a claim on the phone, atomically creating the binding edge.
    public func confirmReversePairingClaim(
        claimID: String,
        as client: ClientIdentity
    ) async throws {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let _: EmptyResponse = try await send(
            method: "POST",
            path: "/v2/clients/me/reverse-pairing-claims/\(claimID)/confirm",
            bearer: client.clientToken
        )
    }

    /// Rejects a claim on the phone. The computer is never told.
    public func rejectReversePairingClaim(
        claimID: String,
        as client: ClientIdentity
    ) async throws {
        guard client.serviceURL == serviceURL else { throw APIError.serviceMismatch }
        let _: EmptyResponse = try await send(
            method: "DELETE",
            path: "/v2/clients/me/reverse-pairing-claims/\(claimID)",
            bearer: client.clientToken
        )
    }
}
