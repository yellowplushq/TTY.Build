import XCTest
@testable import PedalsKit

final class FrameCodecTests: XCTestCase {

    // MARK: Binary frame round-trips

    func testRoundTripAllTypes() throws {
        let payload = Data("payload \u{1B}[31m bytes".utf8)
        for type in Frame.FrameType.allCases {
            let frame = Frame(type: type, sessionId: 7, payload: payload)
            let decoded = try Frame.decode(frame.encoded())
            XCTAssertEqual(decoded, frame, "round trip failed for \(type)")
        }
    }

    func testRoundTripEmptyPayload() throws {
        let frame = Frame(type: .stdin, sessionId: 1, payload: Data())
        let encoded = frame.encoded()
        XCTAssertEqual(encoded.count, 5)
        XCTAssertEqual(try Frame.decode(encoded), frame)
    }

    func testRoundTripLargePayload() throws {
        // replay ring buffer max per spec
        var payload = Data(count: 256 * 1024)
        for i in 0..<payload.count { payload[i] = UInt8(truncatingIfNeeded: i) }
        let frame = Frame.replay(sessionId: 3, data: payload)
        XCTAssertEqual(try Frame.decode(frame.encoded()), frame)
    }

    func testRoundTripMaxSessionId() throws {
        let frame = Frame.stdout(sessionId: .max, data: Data([0x00, 0xFF]))
        XCTAssertEqual(try Frame.decode(frame.encoded()), frame)
    }

    func testWireLayoutIsTypeThenSessionIdLEThenPayload() throws {
        let frame = Frame.stdin(sessionId: 0x0403_0201, data: Data("hi".utf8))
        XCTAssertEqual(frame.encoded(), Data([0x01, 0x01, 0x02, 0x03, 0x04, 0x68, 0x69]))
    }

    func testDecodeOfSlicedDataUsesCorrectIndices() throws {
        // Data slices keep the parent's indices; decode must not assume startIndex == 0.
        let prefixed = Data([0xAA, 0xBB]) + Frame.stdin(sessionId: 5, data: Data("x".utf8)).encoded()
        let slice = prefixed.dropFirst(2)
        XCTAssertEqual(try Frame.decode(slice), Frame.stdin(sessionId: 5, data: Data("x".utf8)))
    }

    func testDecodeTruncatedThrows() {
        for count in 0..<5 {
            XCTAssertThrowsError(try Frame.decode(Data(count: count))) { error in
                XCTAssertEqual(error as? Frame.CodecError, .truncated)
            }
        }
    }

    func testDecodeUnknownTypeThrows() {
        var data = Data([0x05])
        data.append(Data(count: 4))
        XCTAssertThrowsError(try Frame.decode(data)) { error in
            XCTAssertEqual(error as? Frame.CodecError, .unknownType(0x05))
        }
    }

    // MARK: resize payload

    func testResizePayloadEncoding() throws {
        let frame = Frame.resize(sessionId: 2, cols: 120, rows: 40)
        // cols u16 LE (120 = 0x78), rows u16 LE (40 = 0x28)
        XCTAssertEqual(frame.payload, Data([0x78, 0x00, 0x28, 0x00]))
        let size = try frame.resizeSize()
        XCTAssertEqual(size.cols, 120)
        XCTAssertEqual(size.rows, 40)
    }

    func testResizeRoundTripExtremes() throws {
        let frame = Frame.resize(sessionId: 1, cols: .max, rows: 1)
        let decoded = try Frame.decode(frame.encoded())
        let size = try decoded.resizeSize()
        XCTAssertEqual(size.cols, .max)
        XCTAssertEqual(size.rows, 1)
    }

    func testResizeSizeOnWrongTypeOrLengthThrows() {
        XCTAssertThrowsError(try Frame.stdin(sessionId: 1, data: Data(count: 4)).resizeSize())
        XCTAssertThrowsError(try Frame(type: .resize, sessionId: 1, payload: Data(count: 3)).resizeSize())
    }

    // MARK: ctl JSON messages

    func testControlMessageRoundTripAllKinds() throws {
        let hostPrincipal = "0123456789abcdef0123456789abcdef"
        let clientPrincipal = "fedcba9876543210fedcba9876543210"
        let hostNonce = Data(repeating: 0xA1, count: 32)
        let clientNonce = Data(repeating: 0xB2, count: 32)
        let session = SessionInfo(
            id: 1, title: "zsh — ~/dev", cwd: "/Users/x/dev",
            rows: 40, cols: 120, createdAt: 1_752_700_000, alive: true
        )
        let messages: [ControlMessage] = [
            .hello(
                who: .host,
                principal: hostPrincipal,
                connEpoch: 0xDEAD_BEEF,
                nonce: hostNonce,
                ver: 2,
                host: "mac-studio"
            ),
            .hello(
                who: .client,
                principal: clientPrincipal,
                connEpoch: 0,
                nonce: clientNonce,
                ver: 2,
                host: nil
            ),
            .ready(who: .host, echoNonce: clientNonce),
            .ready(who: .client, echoNonce: hostNonce),
            .requestReplay,
            .sessions(list: [session]),
            .sessions(list: []),
            .agents(list: [
                AgentInfo(
                    id: "abc-123", agent: "claude", state: .waiting,
                    cwd: "/Users/x/dev", action: "Bash: git status",
                    message: "Need permission to run git push",
                    prompt: "fix the auth bug", sessionId: 7,
                    term: "iTerm2", updatedAt: 1_752_700_100
                ),
                AgentInfo(
                    id: "def-456", agent: "claude", state: .running,
                    cwd: "/tmp", updatedAt: 1_752_700_200
                ),
            ]),
            .agents(list: []),
            .create(cwd: "/tmp", cols: 80, rows: 24, req: 0xCAFE),
            .create(cwd: nil, cols: 120, rows: 40, req: nil),
            .created(id: 3, req: 0xCAFE),
            .created(id: 3, req: nil),
            .close(id: 2),
            .title(id: 4, title: "vim — notes.md"),
            .exit(id: 5, code: 130),
            .err(msg: "boom"),
        ]
        for message in messages {
            let frame = try Frame.control(message)
            XCTAssertEqual(frame.type, .ctl)
            XCTAssertEqual(frame.sessionId, 0)
            let decoded = try Frame.decode(frame.encoded())
            XCTAssertEqual(try decoded.controlMessage(), message, "round trip failed for \(message)")
        }
    }

    func testAgentStateUnknownValueDecodesAsRunning() throws {
        let json = Data(#"{"t":"agents","agents":[{"id":"x","agent":"claude","state":"pondering","cwd":"/tmp","updatedAt":1}]}"#.utf8)
        guard case let .agents(list) = try ControlMessage(jsonData: json) else {
            return XCTFail("expected agents message")
        }
        XCTAssertEqual(list.first?.state, .running)
    }

    func testControlMessageWireShape() throws {
        let data = try ControlMessage.close(id: 9).jsonData()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["t"] as? String, "close")
        XCTAssertEqual(object["id"] as? Int, 9)
        XCTAssertEqual(object.count, 2)
    }

    func testHelloWireShapeOmitsNilHost() throws {
        let nonce = Data(repeating: 0x5A, count: 32)
        let data = try ControlMessage
            .hello(
                who: .client,
                principal: "fedcba9876543210fedcba9876543210",
                connEpoch: 7,
                nonce: nonce,
                ver: 2,
                host: nil
            ).jsonData()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["host"], "nil host must be omitted, not null")
        XCTAssertEqual(object["t"] as? String, "hello")
        XCTAssertEqual(object["who"] as? String, "client")
        XCTAssertEqual(
            object["principal"] as? String,
            "fedcba9876543210fedcba9876543210"
        )
        XCTAssertEqual(object["connEpoch"] as? Int, 7)
        XCTAssertEqual(object["nonce"] as? String, nonce.base64EncodedString())
        XCTAssertEqual(object["ver"] as? Int, 2)
    }

    func testReadyAndRequestControlMessagesRoundTrip() throws {
        let nonce = Data((0..<32).map(UInt8.init))
        let messages: [ControlMessage] = [
            .ready(who: .client, echoNonce: nonce),
            .requestReplay,
        ]

        for message in messages {
            let encoded = try message.jsonData()
            XCTAssertEqual(try ControlMessage(jsonData: encoded), message)
            XCTAssertEqual(try Frame.control(message).controlMessage(), message)
        }

        let readyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: messages[0].jsonData())
                as? [String: Any]
        )
        XCTAssertEqual(readyObject["t"] as? String, "ready")
        XCTAssertEqual(readyObject["who"] as? String, "client")
        XCTAssertEqual(
            readyObject["echoNonce"] as? String,
            nonce.base64EncodedString()
        )

        let replayObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: messages[1].jsonData())
                as? [String: Any]
        )
        XCTAssertEqual(replayObject["t"] as? String, "requestReplay")
        XCTAssertEqual(replayObject.count, 1)

    }

    func testCreateEncodesNilCwdAsJSONNull() throws {
        let data = try ControlMessage.create(cwd: nil, cols: 120, rows: 40, req: nil).jsonData()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"cwd\":null"), "got \(json)")
        XCTAssertFalse(json.contains("\"req\""), "nil req must be omitted, got \(json)")
    }

    func testDecodesSpecExampleJSON() throws {
        let json = """
        {"t":"sessions","list":[{"id":1,"title":"zsh — ~/dev","cwd":"/Users/x/dev",\
        "rows":40,"cols":120,"createdAt":1752700000,"alive":true}]}
        """
        let message = try ControlMessage(jsonData: Data(json.utf8))
        guard case let .sessions(list) = message else {
            return XCTFail("expected sessions, got \(message)")
        }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, 1)
        XCTAssertEqual(list[0].title, "zsh — ~/dev")
        XCTAssertTrue(list[0].alive)
    }

    func testUnknownControlKindThrows() {
        XCTAssertThrowsError(try ControlMessage(jsonData: Data(#"{"t":"nope"}"#.utf8)))
    }

    func testControlMessageOnNonCtlFrameThrows() {
        XCTAssertThrowsError(try Frame.stdout(sessionId: 1, data: Data()).controlMessage()) { error in
            XCTAssertEqual(error as? Frame.CodecError, .notControlFrame)
        }
    }
}
