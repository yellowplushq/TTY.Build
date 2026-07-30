import Foundation
@testable import PedalsKit
import XCTest

final class RelayMetadataTests: XCTestCase {
    func testHostSnapshotUsesOnlySafeDirectoryFields() throws {
        let metadata = RelayMetadata.hostSnapshot(
            hostName: "Studio",
            sessions: [
                .init(id: 4, alive: true),
                .init(id: 9, alive: false),
            ],
            agents: .init(running: 2, waiting: 1, done: 1)
        )
        let text = try metadata.jsonText()
        XCTAssertEqual(try RelayMetadata(jsonText: text), metadata)
        XCTAssertFalse(text.contains("title"))
        XCTAssertFalse(text.contains("cwd"))
        XCTAssertFalse(text.contains("stdout"))
        XCTAssertFalse(text.contains("message"))
    }

    func testHostSnapshotWithoutAgentCountsDecodesAsZero() throws {
        let text = #"{"hostName":"Studio","sessions":[{"alive":true,"id":3}],"type":"host-snapshot"}"#
        guard case .hostSnapshot(_, _, let agents) = try RelayMetadata(jsonText: text) else {
            return XCTFail("expected host snapshot")
        }
        XCTAssertEqual(agents, .zero)
    }

    func testHostSnapshotRejectsOutOfRangeAgentCounts() {
        let text = #"{"agents":{"running":256,"waiting":0},"hostName":"Studio","sessions":[],"type":"host-snapshot"}"#
        XCTAssertThrowsError(try RelayMetadata(jsonText: text))
        let negative = #"{"agents":{"running":0,"waiting":-1},"hostName":"Studio","sessions":[],"type":"host-snapshot"}"#
        XCTAssertThrowsError(try RelayMetadata(jsonText: negative))
    }

    func testAgentActivityEnvelopeRoundTripsAndRejectsOversizeCiphertext() throws {
        let metadata = RelayMetadata.agentActivity(.init(
            eventID: "11111111-1111-4111-8111-111111111111",
            state: .waiting,
            updatedAt: 1_800_000_000_000,
            alert: true,
            sealed: Data(repeating: 0x42, count: 128)
        ))
        XCTAssertEqual(try RelayMetadata(jsonText: metadata.jsonText()), metadata)

        let oversized = RelayMetadata.agentActivity(.init(
            state: .running,
            updatedAt: 1,
            alert: false,
            sealed: Data(repeating: 0, count: 2_001)
        ))
        XCTAssertThrowsError(try RelayMetadata(jsonText: oversized.jsonText()))
    }

    func testOfflineDirectoryRoundTripsWithReason() throws {
        let metadata = RelayMetadata.terminalDirectory(.init(
            revision: 7,
            online: false,
            hostName: "Studio",
            sessions: [],
            updatedAt: 1_800_000_000,
            reason: .connectionLost
        ))
        XCTAssertEqual(try RelayMetadata(jsonText: metadata.jsonText()), metadata)
    }

    func testChannelStateIsDistinctFromTerminalDirectory() throws {
        let metadata = RelayMetadata.channelState(online: true)
        XCTAssertEqual(try RelayMetadata(jsonText: metadata.jsonText()), metadata)
    }

    func testRejectsDuplicateOrUnorderedDirectoryIDs() {
        let text = #"{"type":"terminal-directory","revision":1,"online":true,"hostName":"Studio","sessions":[{"id":9,"alive":true},{"id":9,"alive":false}],"updatedAt":1}"#
        XCTAssertThrowsError(try RelayMetadata(jsonText: text))
    }

    func testRejectsSessionsInAnOfflineDirectory() {
        let text = #"{"type":"terminal-directory","revision":1,"online":false,"hostName":"Studio","sessions":[{"id":9,"alive":true}],"updatedAt":1,"reason":"connection-lost"}"#
        XCTAssertThrowsError(try RelayMetadata(jsonText: text))
    }
}
