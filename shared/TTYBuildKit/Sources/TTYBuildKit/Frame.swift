import Foundation

/// Plaintext frame per PROTOCOL.md §5:
///
///     frame = type (u8) || sessionId (u32 LE) || payload (bytes)
public struct Frame: Equatable, Sendable {
    public enum FrameType: UInt8, CaseIterable, Sendable {
        case ctl = 0x00     // both directions, sessionId 0, UTF-8 JSON payload
        case stdin = 0x01   // client→host, raw bytes to write to PTY
        case stdout = 0x02  // host→client, raw PTY output bytes
        case resize = 0x03  // client→host, cols u16 LE || rows u16 LE
        case replay = 0x04  // host→client, scrollback ring buffer snapshot
    }

    public enum CodecError: Error, Equatable {
        case truncated
        case unknownType(UInt8)
        case notControlFrame
        case invalidResizePayload
    }

    public var type: FrameType
    public var sessionId: UInt32
    public var payload: Data

    public init(type: FrameType, sessionId: UInt32, payload: Data) {
        self.type = type
        self.sessionId = sessionId
        self.payload = payload
    }

    // MARK: Wire format

    public func encoded() -> Data {
        var data = Data(capacity: 5 + payload.count)
        data.append(type.rawValue)
        data.appendUInt32LE(sessionId)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> Frame {
        guard data.count >= 5 else { throw CodecError.truncated }
        let start = data.startIndex
        let rawType = data[start]
        guard let type = FrameType(rawValue: rawType) else {
            throw CodecError.unknownType(rawType)
        }
        let sessionId = data.uint32LE(at: start + 1)
        let payload = Data(data[(start + 5)...])
        return Frame(type: type, sessionId: sessionId, payload: payload)
    }

    // MARK: Convenience constructors / accessors

    public static func control(_ message: ControlMessage) throws -> Frame {
        Frame(type: .ctl, sessionId: 0, payload: try message.jsonData())
    }

    public func controlMessage() throws -> ControlMessage {
        guard type == .ctl else { throw CodecError.notControlFrame }
        return try ControlMessage(jsonData: payload)
    }

    public static func stdin(sessionId: UInt32, data: Data) -> Frame {
        Frame(type: .stdin, sessionId: sessionId, payload: data)
    }

    public static func stdout(sessionId: UInt32, data: Data) -> Frame {
        Frame(type: .stdout, sessionId: sessionId, payload: data)
    }

    public static func replay(sessionId: UInt32, data: Data) -> Frame {
        Frame(type: .replay, sessionId: sessionId, payload: data)
    }

    public static func resize(sessionId: UInt32, cols: UInt16, rows: UInt16) -> Frame {
        var payload = Data(capacity: 4)
        payload.appendUInt16LE(cols)
        payload.appendUInt16LE(rows)
        return Frame(type: .resize, sessionId: sessionId, payload: payload)
    }

    public func resizeSize() throws -> (cols: UInt16, rows: UInt16) {
        guard type == .resize, payload.count == 4 else {
            throw CodecError.invalidResizePayload
        }
        let start = payload.startIndex
        return (cols: payload.uint16LE(at: start), rows: payload.uint16LE(at: start + 2))
    }
}

// MARK: - Little-endian helpers (shared across the package)

extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// `index` is an absolute Data index; caller guarantees bounds.
    func uint16LE(at index: Index) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    func uint32LE(at index: Index) -> UInt32 {
        var value: UInt32 = 0
        for offset in (0..<4).reversed() {
            value = value << 8 | UInt32(self[index + offset])
        }
        return value
    }

    func uint64LE(at index: Index) -> UInt64 {
        var value: UInt64 = 0
        for offset in (0..<8).reversed() {
            value = value << 8 | UInt64(self[index + offset])
        }
        return value
    }
}
