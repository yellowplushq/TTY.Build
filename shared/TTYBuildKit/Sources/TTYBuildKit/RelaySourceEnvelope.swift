import Foundation

/// Relay-authenticated source metadata prepended only to client-to-host binary
/// messages. The Durable Object creates this header from its serialized,
/// bearer-authenticated socket attachment; peers never create it themselves.
///
///     0x02 || clientId(32 lowercase ASCII hex bytes) || E2EE wire
///
/// A host RelayLink requires this envelope. A client RelayLink continues to
/// receive the unmodified E2EE wire from the host.
struct RelaySourceEnvelope: Equatable, Sendable {
    static let version: UInt8 = 0x02
    static let principalByteCount = 32
    static let headerByteCount = 1 + principalByteCount

    let principal: String
    let wire: Data

    init?(data: Data) {
        guard data.count > Self.headerByteCount else { return nil }
        let start = data.startIndex
        guard data[start] == Self.version else { return nil }
        let principalStart = data.index(after: start)
        let principalEnd = data.index(
            principalStart, offsetBy: Self.principalByteCount
        )
        let principalBytes = data[principalStart..<principalEnd]
        guard principalBytes.allSatisfy(Self.isLowercaseASCIIHex) else {
            return nil
        }
        principal = String(decoding: principalBytes, as: UTF8.self)
        wire = Data(data[principalEnd...])
    }

    static func isCanonicalPrincipal(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == principalByteCount
            && bytes.allSatisfy(isLowercaseASCIIHex)
    }

    /// Returns the stable peer identity only when the encrypted hello agrees
    /// with the identity authenticated by the transport for this local role.
    static func authenticatedHelloPrincipal(
        localRole: PeerRole,
        envelopeSource: String?,
        claimedPrincipal: String,
        computerID: String
    ) -> String? {
        switch localRole {
        case .host:
            guard let envelopeSource,
                  claimedPrincipal == envelopeSource
            else { return nil }
            return envelopeSource
        case .client:
            guard envelopeSource == nil,
                  claimedPrincipal == computerID
            else { return nil }
            return computerID
        }
    }

    /// Pending and active ciphers are source-bound before decryption so a
    /// cross-client injection cannot consume another client's receive counter.
    static func authorizesPeerFrame(
        localRole: PeerRole,
        envelopeSource: String?,
        boundPrincipal: String?
    ) -> Bool {
        switch localRole {
        case .host:
            guard let envelopeSource, let boundPrincipal else { return false }
            return envelopeSource == boundPrincipal
        case .client:
            return envelopeSource == nil && boundPrincipal != nil
        }
    }

    private static func isLowercaseASCIIHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}
