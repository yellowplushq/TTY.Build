import CryptoKit
import Foundation

/// Direction keys per PROTOCOL.md §4.1–§4.3:
///
///     key_h2c = HKDF-SHA256(ikm=secret, salt="ttybuild-v2", info="host->client"<chan>, 32)
///     key_c2h = HKDF-SHA256(ikm=secret, salt="ttybuild-v2", info="client->host"<chan>, 32)
///
/// `<chan>` binds the key to the channel so that a ciphertext captured on one
/// channel cannot be re-routed by the (untrusted) relay onto another channel of
/// the same room — it fails to decrypt under the target channel's key. The
/// control channel uses no suffix, while each session
/// channel appends `:session:<sid>`.
public enum KeyDerivation {
    public static let salt = Data("ttybuild-v2".utf8)
    public static let keyByteCount = 32

    /// Fresh nonces contributed by both peers bind traffic keys to the live
    /// socket handshake. Replaying a captured hello on a later connection
    /// cannot recreate a key because the other peer's nonce has changed.
    public struct ConnectionBinding: Equatable, Sendable {
        public static let nonceByteCount = 32
        public let hostNonce: Data
        public let clientNonce: Data

        public init(hostNonce: Data, clientNonce: Data) {
            precondition(hostNonce.count == Self.nonceByteCount)
            precondition(clientNonce.count == Self.nonceByteCount)
            self.hostNonce = hostNonce
            self.clientNonce = clientNonce
        }

        fileprivate var salt: Data {
            var input = Data("ttybuild-v2-connection".utf8)
            input.append(hostNonce)
            input.append(clientNonce)
            return Data(SHA256.hash(data: input))
        }

        /// Cleartext routing tag used only to select one of several E2EE
        /// client channels on the daemon's aggregate relay socket.
        public var tag: Data {
            var input = Data("ttybuild-v2-tag".utf8)
            input.append(hostNonce)
            input.append(clientNonce)
            return Data(SHA256.hash(data: input).prefix(16))
        }
    }

    /// Channel identity folded into key derivation.
    public enum Channel: Sendable, Equatable {
        case control
        case session(UInt32)

        var infoSuffix: String {
            switch self {
            case .control: ""
            case .session(let sid): ":session:\(sid)"
            }
        }
    }

    public static func hostToClientKey(
        secret: Data,
        channel: Channel = .control,
        connection: ConnectionBinding? = nil
    ) -> SymmetricKey {
        derive(
            secret: secret,
            salt: connection?.salt ?? salt,
            info: "host->client" + channel.infoSuffix
        )
    }

    public static func clientToHostKey(
        secret: Data,
        channel: Channel = .control,
        connection: ConnectionBinding? = nil
    ) -> SymmetricKey {
        derive(
            secret: secret,
            salt: connection?.salt ?? salt,
            info: "client->host" + channel.infoSuffix
        )
    }

    private static func derive(secret: Data, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: keyByteCount
        )
    }
}
