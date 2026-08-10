import CryptoKit
import Foundation

/// The user-visible rendezvous handle. It admits pairing claims for its
/// issuer-chosen lifetime, but is never used as E2EE key material.
public struct PairingCode: Codable, Equatable, Hashable, Sendable {
    public static let digitCount = 8
    public let digits: String

    public enum ValidationError: Error, Equatable {
        case invalidFormat
    }

    public init(_ value: String) throws {
        let compact = value.filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == Self.digitCount,
              compact.allSatisfy({ $0.isASCII && $0.isNumber })
        else { throw ValidationError.invalidFormat }
        digits = compact
    }

    public var formatted: String {
        "\(digits.prefix(4)) \(digits.suffix(4))"
    }
}

/// Host-side state retained while the desktop pairing page is open.
public struct HostPairingCode: Equatable, Sendable {
    public let codeID: String
    public let code: PairingCode
    public let expiresAt: Int64
    public let privateKey: Data

    public init(codeID: String, code: PairingCode, expiresAt: Int64, privateKey: Data) {
        self.codeID = codeID
        self.code = code
        self.expiresAt = expiresAt
        self.privateKey = privateKey
    }
}

public enum HostPairingCodeStatus: Equatable, Sendable {
    case waiting
    case claimed(claimID: String, clientPublicKey: Data)
    case completed
}

/// One shared key-agreement construction for the whole pairing surface: the
/// computer seals its 32-byte E2EE secret to a client-provided Curve25519
/// public key, bound to the server-issued claim ID as both HKDF info and
/// AEAD associated data.
enum PairingKeyAgreement {
    static let salt = Data("tty.build pairing v3".utf8)

    static func makePrivateKey() -> Data {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation
    }

    static func publicKey(for privateKey: Data) throws -> Data {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            .publicKey.rawRepresentation
    }

    static func seal(
        secret: Data,
        hostPrivateKey: Data,
        clientPublicKey: Data,
        claimID: String
    ) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hostPrivateKey)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublicKey)
        let key = try deriveKey(privateKey: privateKey, publicKey: publicKey, claimID: claimID)
        return try ChaChaPoly.seal(
            secret,
            using: key,
            authenticating: Data(claimID.utf8)
        ).combined
    }

    static func open(
        envelope: Data,
        clientPrivateKey: Data,
        hostPublicKey: Data,
        claimID: String
    ) throws -> Data {
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: clientPrivateKey)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublicKey)
        let key = try deriveKey(privateKey: privateKey, publicKey: publicKey, claimID: claimID)
        return try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: envelope),
            using: key,
            authenticating: Data(claimID.utf8)
        )
    }

    private static func deriveKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey,
        claimID: String
    ) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(claimID.utf8),
            outputByteCount: 32
        )
    }
}
