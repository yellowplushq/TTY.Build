import CryptoKit
import XCTest
@testable import TTYBuildKit

/// Cross-implementation test vectors, shared verbatim with the Node reference
/// implementation (relay/test/crypto-ref.mjs). Canonical copy with derivations:
/// shared/TTYBuildKit/TESTVECTORS.md.
///
///   secret     = 32 bytes of 0x42
///   key_h2c    = HKDF-SHA256(ikm=secret, salt="ttybuild-v2", info="host->client", 32)
///              = f57dfa58483b0961b807a597accdf09ad32d7898d6068e2e27606dddced0e878
///   key_c2h    = HKDF-SHA256(ikm=secret, salt="ttybuild-v2", info="client->host", 32)
///              = bfcae2fa3792508f62ad8fbf386d04ca61577abf5dfed1b3b236dcb16fe3ed96
///
/// Sealed-message vector (direction host->client, key_h2c):
///   plaintext  = ctl frame: type 0x00 || sessionId 0 (u32 LE) || "hello"
///              = 000000000068656c6c6f
///   seq        = 1, AAD = 0100000000000000 (u64 LE)
///   nonce      = "ttybld-nonce" = 747479626c642d6e6f6e6365
///                (nonces are random on the wire; this one was fixed once at vector
///                 generation time so both implementations can assert exact bytes)
///   message    = seq || nonce || ciphertext || tag
///              = 0100000000000000747479626c642d6e6f6e6365575f3c48a735ba95
///                833481d24d2f06b0a8c4b6ffd7a33074321e
final class TestVectorTests: XCTestCase {
    private let secret = Data(repeating: 0x42, count: 32)

    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    func testHKDFHostToClientVector() {
        XCTAssertEqual(
            hex(KeyDerivation.hostToClientKey(secret: secret)),
            "f57dfa58483b0961b807a597accdf09ad32d7898d6068e2e27606dddced0e878"
        )
    }

    func testHKDFClientToHostVector() {
        XCTAssertEqual(
            hex(KeyDerivation.clientToHostKey(secret: secret)),
            "bfcae2fa3792508f62ad8fbf386d04ca61577abf5dfed1b3b236dcb16fe3ed96"
        )
    }

    /// Dedicated to Live Activity content so widget access exposes no relay traffic.
    func testHKDFLiveActivityKeyVector() {
        XCTAssertEqual(
            hex(AgentActivity.activityKey(secret: secret)),
            "1c0647f1c9985a1b7b18877fb8989763fdbb4fe04d168100cf136dcb51a95a60"
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

    func testAgentActivitySecondCompanionRoundTripsAndStaysOptional() throws {
        let key = AgentActivity.activityKey(secret: secret)
        let content = AgentActivity.Content(
            id: "a-1", agent: "claude", state: .running, project: "proj",
            updatedAt: 1_000,
            second: .init(
                id: "a-2", agent: "codex", state: .waiting,
                sessionName: "Second session", updatedAt: 900
            )
        )
        let sealed = try AgentActivity.seal(content, key: key, computerID: "c-1")
        XCTAssertEqual(try AgentActivity.open(sealed, key: key, computerID: "c-1"), content)

        // Envelopes from daemons that predate the second row decode with no
        // second companion, not a decoding failure.
        var withoutSecond = content
        withoutSecond.second = nil
        let older = try AgentActivity.seal(withoutSecond, key: key, computerID: "c-1")
        XCTAssertNil(try AgentActivity.open(older, key: key, computerID: "c-1").second)
    }

    func testSealedMessageVectorDecrypts() throws {
        let message = Data(hexString:
            "0100000000000000" // seq = 1, u64 LE
            + "747479626c642d6e6f6e6365" // nonce "ttybld-nonce"
            + "575f3c48a735ba958334" // ciphertext (10 bytes)
            + "81d24d2f06b0a8c4b6ffd7a33074321e" // Poly1305 tag (16 bytes)
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
            "0100000000000000747479626c642d6e6f6e6365575f3c48a735ba95"
            + "833481d24d2f06b0a8c4b6ffd7a33074321e"
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
            "0100000000000000747479626c642d6e6f6e6365575f3c48a735ba95"
            + "833481d24d2f06b0a8c4b6ffd7a33074321e"
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
