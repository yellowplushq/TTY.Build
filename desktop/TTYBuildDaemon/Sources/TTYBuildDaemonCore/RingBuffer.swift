import Foundation

/// Fixed-capacity byte ring buffer: keeps the most recent `capacity` bytes appended.
/// Used for the per-session 256 KB scrollback replayed on attach (PROTOCOL.md §4/§6).
public struct RingBuffer: Sendable {
    /// Per-session scrollback size mandated by PROTOCOL.md §6.
    public static let sessionCapacity = 256 * 1024

    public let capacity: Int
    private var storage: [UInt8]
    /// Index of the oldest byte when full; write position otherwise.
    private var head = 0
    public private(set) var count = 0

    public init(capacity: Int = RingBuffer.sessionCapacity) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        storage = [UInt8](repeating: 0, count: capacity)
    }

    public mutating func append(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var bytes = raw.baseAddress.map({ $0.assumingMemoryBound(to: UInt8.self) })
            else { return }
            var remaining = raw.count
            // Only the last `capacity` bytes of oversized appends can survive.
            if remaining > capacity {
                bytes += remaining - capacity
                remaining = capacity
            }
            let writeIndex = (head + count) % capacity
            let overwritten = max(0, count + remaining - capacity)
            for i in 0..<remaining {
                storage[(writeIndex + i) % capacity] = bytes[i]
            }
            count = min(capacity, count + remaining)
            head = (head + overwritten) % capacity
        }
    }

    /// The buffered bytes, oldest first.
    public func snapshot() -> Data {
        var out = Data(capacity: count)
        let firstRun = min(count, capacity - head)
        out.append(contentsOf: storage[head..<(head + firstRun)])
        if firstRun < count {
            out.append(contentsOf: storage[0..<(count - firstRun)])
        }
        return out
    }
}
