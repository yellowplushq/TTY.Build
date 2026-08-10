import CryptoKit
import Foundation

/// Seals/opens full WebSocket binary messages per PROTOCOL.md §4:
///
///     message = seq (u64 LE) || ChaChaPoly.seal(plaintextFrame,
///                                               key=direction key, aad=seq bytes).combined
///
/// `combined` = nonce(12) || ciphertext || tag(16).
///
/// `seq = connEpoch (u32) << 32 | counter (u32)`: every WebSocket connection
/// picks a random `connEpoch` and counts from 1 within it. The receiver keeps
/// the highest accepted counter *per epoch* and drops non-increasing counters,
/// so N concurrent peer connections on one channel (each its own epoch) don't
/// clash, and traffic replayed from an old connection stays rejected. Create a
/// fresh SecureChannel for every WebSocket connection.
public struct SecureChannel: Sendable {
    public enum ChannelError: Error, Equatable {
        case malformedMessage
        /// The counter was not strictly greater than the last accepted counter
        /// for that connEpoch (replay / reorder).
        case staleSequence(received: UInt64, lastAccepted: UInt64)
        case decryptionFailed
    }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let epochBase: UInt64
    private var sendCounter: UInt32 = 0
    /// Highest accepted counter per peer connEpoch. Bounded by the number of
    /// peer connections seen over this socket's lifetime.
    private var lastReceived: [UInt32: UInt32] = [:]
    private var receivedEpochOrder: [UInt32] = []
    private static let maximumTrackedReceiveEpochs = 256

    /// This side's connection epoch — also announced in the `hello` ctl.
    public let connEpoch: UInt32

    /// minimum message length: seq(8) + nonce(12) + tag(16); empty plaintext is legal.
    private static let minimumMessageLength = 8 + 12 + 16

    /// Derives both direction keys from the pairing secret for the given local
    /// role, bound to `channel` so ciphertext cannot cross channels (§4.3).
    public init(
        secret: Data, role: PeerRole,
        channel: KeyDerivation.Channel = .control,
        connEpoch: UInt32 = UInt32.random(in: .min ... .max),
        connection: KeyDerivation.ConnectionBinding? = nil
    ) {
        let h2c = KeyDerivation.hostToClientKey(
            secret: secret, channel: channel, connection: connection
        )
        let c2h = KeyDerivation.clientToHostKey(
            secret: secret, channel: channel, connection: connection
        )
        switch role {
        case .host:
            sendKey = h2c
            receiveKey = c2h
        case .client:
            sendKey = c2h
            receiveKey = h2c
        }
        self.connEpoch = connEpoch
        epochBase = UInt64(connEpoch) << 32
    }

    /// seq assigned to the next sealed message.
    public var nextSendSeq: UInt64 { epochBase | UInt64(sendCounter + 1) }

    /// Encrypts a plaintext frame into a full WebSocket message.
    public mutating func seal(_ plaintext: Data, context: Data = Data()) throws -> Data {
        // 2^32 messages per connection is unreachable in practice; reconnecting
        // (fresh epoch) resets the counter long before.
        sendCounter += 1
        let seq = epochBase | UInt64(sendCounter)
        var seqBytes = Data(capacity: 8)
        seqBytes.appendUInt64LE(seq)
        var authenticatedData = context
        authenticatedData.append(seqBytes)
        let box = try ChaChaPoly.seal(
            plaintext, using: sendKey, authenticating: authenticatedData
        )
        var message = seqBytes
        message.append(box.combined)
        return message
    }

    public mutating func seal(_ frame: Frame, context: Data = Data()) throws -> Data {
        try seal(frame.encoded(), context: context)
    }

    /// Decrypts a full WebSocket message, enforcing a strictly increasing
    /// counter within the sender's connEpoch. Per spec, `.decryptionFailed`
    /// means the caller must close the connection; `.staleSequence` means
    /// drop the message and continue.
    public mutating func open(_ message: Data, context: Data = Data()) throws -> Data {
        try openWithSequence(message, context: context).plaintext
    }

    /// The sequence is exposed for the bootstrap hello so RelayLink can prove
    /// that its encrypted `connEpoch` declaration matches the AEAD header.
    public mutating func openWithSequence(
        _ message: Data,
        context: Data = Data()
    ) throws -> (sequence: UInt64, plaintext: Data) {
        let (seq, plaintext) = try decrypt(message, context: context)
        let epoch = UInt32(truncatingIfNeeded: seq >> 32)
        let counter = UInt32(truncatingIfNeeded: seq)
        let last = lastReceived[epoch] ?? 0
        guard counter > last else {
            throw ChannelError.staleSequence(
                received: seq, lastAccepted: UInt64(epoch) << 32 | UInt64(last)
            )
        }
        if lastReceived[epoch] == nil {
            if receivedEpochOrder.count >= Self.maximumTrackedReceiveEpochs {
                let oldest = receivedEpochOrder.removeFirst()
                lastReceived.removeValue(forKey: oldest)
            }
            receivedEpochOrder.append(epoch)
        }
        lastReceived[epoch] = counter
        return (seq, plaintext)
    }

    private func decrypt(
        _ message: Data,
        context: Data
    ) throws -> (seq: UInt64, plaintext: Data) {
        guard message.count >= Self.minimumMessageLength else {
            throw ChannelError.malformedMessage
        }
        let start = message.startIndex
        let seq = message.uint64LE(at: start)
        let seqBytes = Data(message[start..<(start + 8)])
        var authenticatedData = context
        authenticatedData.append(seqBytes)
        do {
            let box = try ChaChaPoly.SealedBox(combined: message[(start + 8)...])
            return (
                seq,
                try ChaChaPoly.open(
                    box, using: receiveKey, authenticating: authenticatedData
                )
            )
        } catch {
            throw ChannelError.decryptionFailed
        }
    }

    /// Decrypts and decodes a plaintext frame in one step.
    public mutating func openFrame(_ message: Data, context: Data = Data()) throws -> Frame {
        try Frame.decode(try open(message, context: context))
    }
}
