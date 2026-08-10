import XCTest
@testable import TTYBuildKit

final class SecureChannelTests: XCTestCase {
    private let secret = Data(repeating: 0x42, count: 32)

    /// Deterministic epochs (0) so seq assertions read as plain counters.
    private func pair() -> (host: SecureChannel, client: SecureChannel) {
        (SecureChannel(secret: secret, role: .host, connEpoch: 0),
         SecureChannel(secret: secret, role: .client, connEpoch: 0))
    }

    func testSealOpenRoundTripBothDirections() throws {
        var (host, client) = pair()
        let h2c = Data("host says hi".utf8)
        let c2h = Data("client says hi".utf8)
        XCTAssertEqual(try client.open(try host.seal(h2c)), h2c)
        XCTAssertEqual(try host.open(try client.seal(c2h)), c2h)
    }

    func testFrameConvenienceRoundTrip() throws {
        var (host, client) = pair()
        let frame = try Frame.control(.hello(
            who: .host,
            principal: "0123456789abcdef0123456789abcdef",
            connEpoch: 123,
            nonce: Data(repeating: 0x44, count: 32),
            ver: 2,
            host: nil
        ))
        XCTAssertEqual(try client.openFrame(try host.seal(frame)), frame)
    }

    func testSeqEmbedsEpochAndCounterStartsAtOne() throws {
        var host = SecureChannel(secret: secret, role: .host, connEpoch: 0xAABB_CCDD)
        XCTAssertEqual(host.nextSendSeq, 0xAABB_CCDD_0000_0001)
        for counter in UInt64(1)...3 {
            let message = try host.seal(Data("x".utf8))
            XCTAssertEqual(
                message.uint64LE(at: message.startIndex),
                0xAABB_CCDD << 32 | counter
            )
        }
    }

    func testReplayIsRejected() throws {
        var (host, client) = pair()
        let message = try host.seal(Data("once".utf8))
        _ = try client.open(message)
        XCTAssertThrowsError(try client.open(message)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 1)
            )
        }
    }

    func testOutOfOrderSeqIsRejected() throws {
        var (host, client) = pair()
        let first = try host.seal(Data("1".utf8))
        let second = try host.seal(Data("2".utf8))
        _ = try client.open(second)
        XCTAssertThrowsError(try client.open(first)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 2)
            )
        }
    }

    func testSeqGapsAreAccepted() throws {
        // Relay drops messages when the peer is absent, so gaps are legal.
        var (host, client) = pair()
        _ = try host.seal(Data("dropped".utf8))
        let message = try host.seal(Data("arrives".utf8))
        XCTAssertEqual(try client.open(message), Data("arrives".utf8))
    }

    /// N clients on one broadcast channel each have their own connEpoch; the
    /// host must accept their interleaved counters independently.
    func testConcurrentPeerEpochsAreTrackedIndependently() throws {
        var host = SecureChannel(secret: secret, role: .host, connEpoch: 0)
        var clientA = SecureChannel(secret: secret, role: .client, connEpoch: 1)
        var clientB = SecureChannel(secret: secret, role: .client, connEpoch: 2)

        let a1 = try clientA.seal(Data("a1".utf8))
        let a2 = try clientA.seal(Data("a2".utf8))
        let b1 = try clientB.seal(Data("b1".utf8))

        XCTAssertEqual(try host.open(a1), Data("a1".utf8))
        XCTAssertEqual(try host.open(a2), Data("a2".utf8))
        // clientB's counter restarts at 1 but lives in its own epoch.
        XCTAssertEqual(try host.open(b1), Data("b1".utf8))
        // Replaying clientA's traffic is still rejected within epoch 1.
        XCTAssertThrowsError(try host.open(a1)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1 << 32 | 1, lastAccepted: 1 << 32 | 2)
            )
        }
    }

    /// A reconnecting peer picks a fresh epoch; no receive-state reset needed,
    /// and traffic replayed from its previous connection stays rejected.
    func testFreshPeerConnectionAcceptedWithoutReset() throws {
        var host = SecureChannel(secret: secret, role: .host, connEpoch: 0)
        var oldClient = SecureChannel(secret: secret, role: .client, connEpoch: 7)
        let oldMessage = try oldClient.seal(Data("old".utf8))
        _ = try host.open(oldMessage)

        var freshClient = SecureChannel(secret: secret, role: .client, connEpoch: 8)
        XCTAssertEqual(try host.open(try freshClient.seal(Data("hello again".utf8))),
                       Data("hello again".utf8))
        XCTAssertThrowsError(try host.open(oldMessage)) // old epoch replay
    }

    func testFailedDecryptDoesNotAdvanceReceiveSeq() throws {
        var (host, client) = pair()
        var tampered = try host.seal(Data("payload".utf8))
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try client.open(tampered)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
        // A clean retransmit of seq 1 must still be acceptable.
        var freshHost = SecureChannel(secret: secret, role: .host, connEpoch: 0)
        XCTAssertEqual(try client.open(try freshHost.seal(Data("payload".utf8))), Data("payload".utf8))
    }

    func testTamperedSeqFailsAuthentication() throws {
        var (host, client) = pair()
        var message = try host.seal(Data("payload".utf8))
        // Bump seq (AAD) without re-sealing: passes the monotonic check, fails the tag.
        message[message.startIndex] = 2
        XCTAssertThrowsError(try client.open(message)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }

    func testWrongDirectionKeyFailsDecryption() throws {
        var (host, _) = pair()
        var otherHost = SecureChannel(secret: secret, role: .host, connEpoch: 0)
        let message = try host.seal(Data("payload".utf8))
        // A host must not be able to open host->client traffic.
        XCTAssertThrowsError(try otherHost.open(message)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }

    func testTooShortMessageIsMalformed() {
        var (_, client) = pair()
        XCTAssertThrowsError(try client.open(Data(count: 35))) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .malformedMessage)
        }
    }

    /// Per-channel keys: a ciphertext sealed on one channel must not decrypt on
    /// another channel of the same room (untrusted-relay cross-injection, §3).
    func testCiphertextDoesNotCrossChannels() throws {
        // Client seals stdin for session 1.
        var s1Client = SecureChannel(secret: secret, role: .client, channel: .session(1))
        let sealed = try s1Client.seal(Data("rm -rf important/\n".utf8))

        // Host on a *different* session channel must reject it at decrypt.
        var s2Host = SecureChannel(secret: secret, role: .host, channel: .session(2))
        XCTAssertThrowsError(try s2Host.open(sealed)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
        // The control channel must reject it too.
        var controlHost = SecureChannel(secret: secret, role: .host, channel: .control)
        XCTAssertThrowsError(try controlHost.open(sealed)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
        // The matching session-1 host still opens it.
        var s1Host = SecureChannel(secret: secret, role: .host, channel: .session(1))
        XCTAssertEqual(try s1Host.open(sealed), Data("rm -rf important/\n".utf8))
    }

    func testRoutingTagIsAuthenticatedAsContext() throws {
        let binding = KeyDerivation.ConnectionBinding(
            hostNonce: Data(repeating: 0x10, count: 32),
            clientNonce: Data(repeating: 0x20, count: 32)
        )
        var host = SecureChannel(
            secret: secret,
            role: .host,
            connEpoch: 1,
            connection: binding
        )
        var client = SecureChannel(
            secret: secret,
            role: .client,
            connEpoch: 2,
            connection: binding
        )
        let ciphertext = try host.seal(
            Data("connection-bound".utf8),
            context: binding.tag
        )
        let wrongTag = Data(repeating: 0xFF, count: 16)

        XCTAssertThrowsError(try client.open(ciphertext, context: wrongTag)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
        XCTAssertEqual(
            try client.open(ciphertext, context: binding.tag),
            Data("connection-bound".utf8)
        )
    }

    func testCiphertextFromPreviousNonceBindingFailsOnFreshConnection() throws {
        let hostNonce = Data(repeating: 0x31, count: 32)
        let oldBinding = KeyDerivation.ConnectionBinding(
            hostNonce: hostNonce,
            clientNonce: Data(repeating: 0x41, count: 32)
        )
        let freshBinding = KeyDerivation.ConnectionBinding(
            hostNonce: hostNonce,
            clientNonce: Data(repeating: 0x42, count: 32)
        )
        var oldHost = SecureChannel(
            secret: secret,
            role: .host,
            connEpoch: 7,
            connection: oldBinding
        )
        let historicalCiphertext = try oldHost.seal(
            Data("captured from old socket".utf8),
            context: oldBinding.tag
        )
        var freshClient = SecureChannel(
            secret: secret,
            role: .client,
            connEpoch: 8,
            connection: freshBinding
        )

        // Keep the original routing context to isolate the connection-key
        // change: fresh peer nonces alone make historical traffic invalid.
        XCTAssertThrowsError(
            try freshClient.open(historicalCiphertext, context: oldBinding.tag)
        ) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }

    /// The control channel's keys use no channel suffix, so
    /// the cross-implementation test vectors keep matching.
    func testControlChannelKeysAreUnsuffixed() {
        let a = KeyDerivation.hostToClientKey(secret: secret)
        let b = KeyDerivation.hostToClientKey(secret: secret, channel: .control)
        XCTAssertEqual(a.withUnsafeBytes { Data($0) }, b.withUnsafeBytes { Data($0) })
    }

    func testEmptyPlaintextRoundTrips() throws {
        var (host, client) = pair()
        let message = try host.seal(Data())
        XCTAssertEqual(message.count, 8 + 12 + 16)
        XCTAssertEqual(try client.open(message), Data())
    }
}
