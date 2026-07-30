import CryptoKit
import XCTest
@testable import PedalsKit

/// Cross-implementation test vectors, shared verbatim with the Node reference
/// implementation (relay/test/crypto-ref.mjs). Canonical copy with derivations:
/// shared/PedalsKit/TESTVECTORS.md.
///
///   secret     = 32 bytes of 0x42
///   key_h2c    = HKDF-SHA256(ikm=secret, salt="pedals-v2", info="host->client", 32)
///              = 6972bc6da52c7ca19a55c1304c25846b032531a6142175312d54fdf09592ff40
///   key_c2h    = HKDF-SHA256(ikm=secret, salt="pedals-v2", info="client->host", 32)
///              = 92961f97fbed1c21af672ab1f143c8b13589b10b849b0afed483aaff6cc4b3b7
///
/// Sealed-message vector (direction host->client, key_h2c):
///   plaintext  = ctl frame: type 0x00 || sessionId 0 (u32 LE) || "hello"
///              = 000000000068656c6c6f
///   seq        = 1, AAD = 0100000000000000 (u64 LE)
///   nonce      = "pedals-nonce" = 706564616c732d6e6f6e6365
///                (nonces are random on the wire; this one was fixed once at vector
///                 generation time so both implementations can assert exact bytes)
///   message    = seq || nonce || ciphertext || tag
///              = 0100000000000000706564616c732d6e6f6e636594d3740a19c7dc46
///                5ace5279fe452d7a661383a99da076062944
final class TestVectorTests: XCTestCase {
    private let secret = Data(repeating: 0x42, count: 32)

    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    func testHKDFHostToClientVector() {
        XCTAssertEqual(
            hex(KeyDerivation.hostToClientKey(secret: secret)),
            "6972bc6da52c7ca19a55c1304c25846b032531a6142175312d54fdf09592ff40"
        )
    }

    func testHKDFClientToHostVector() {
        XCTAssertEqual(
            hex(KeyDerivation.clientToHostKey(secret: secret)),
            "92961f97fbed1c21af672ab1f143c8b13589b10b849b0afed483aaff6cc4b3b7"
        )
    }

    /// Dedicated to Live Activity content so widget access exposes no relay traffic.
    func testHKDFLiveActivityKeyVector() {
        XCTAssertEqual(
            hex(AgentActivity.activityKey(secret: secret)),
            "aa9edd51002b92bf44e19b91f97ea7ee79f2416c460e36f25be4d0c71e2b2912"
        )
    }

    func testAgentActivitySealRoundTripsAndBindsComputerID() throws {
        let key = AgentActivity.activityKey(secret: secret)
        let content = AgentActivity.Content(
            id: "a-1", agent: "claude", state: .waiting, project: "proj",
            message: "Waiting for your answer", sessionId: 7, updatedAt: 1_000
        )
        let sealed = try AgentActivity.seal(content, key: key, computerID: "c-1")
        XCTAssertEqual(try AgentActivity.open(sealed, key: key, computerID: "c-1"), content)
        XCTAssertThrowsError(try AgentActivity.open(sealed, key: key, computerID: "c-2"))
    }

    func testSealedMessageVectorDecrypts() throws {
        let message = Data(hexString:
            "0100000000000000" // seq = 1, u64 LE
            + "706564616c732d6e6f6e6365" // nonce "pedals-nonce"
            + "94d3740a19c7dc465ace" // ciphertext (10 bytes)
            + "5279fe452d7a661383a99da076062944" // Poly1305 tag (16 bytes)
        )!
        var client = SecureChannel(secret: secret, role: .client)
        let plaintext = try client.open(message)
        XCTAssertEqual(plaintext, Data(hexString: "000000000068656c6c6f")!)

        let frame = try Frame.decode(plaintext)
        XCTAssertEqual(frame.type, .ctl)
        XCTAssertEqual(frame.sessionId, 0)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "hello")
    }

    func testSealedMessageVectorRejectsReplay() throws {
        let message = Data(hexString:
            "0100000000000000706564616c732d6e6f6e636594d3740a19c7dc46"
            + "5ace5279fe452d7a661383a99da076062944"
        )!
        var client = SecureChannel(secret: secret, role: .client)
        _ = try client.open(message)
        XCTAssertThrowsError(try client.open(message)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 1)
            )
        }
    }

    /// The vector's host->client blob must not open with the client->host key.
    func testSealedMessageVectorDirectionality() {
        let message = Data(hexString:
            "0100000000000000706564616c732d6e6f6e636594d3740a19c7dc46"
            + "5ace5279fe452d7a661383a99da076062944"
        )!
        var host = SecureChannel(secret: secret, role: .host)
        XCTAssertThrowsError(try host.open(message)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
