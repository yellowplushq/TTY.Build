import CryptoKit
import Foundation
import PedalsKit
import XCTest
@testable import Pedals

final class AgentActivityKeyStoreTests: XCTestCase {
    func testFileStoreReplacesKeysAtomicallyAndRemovesStaleEntries() throws {
        let (directory, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstID = String(repeating: "a", count: 32)
        let secondID = String(repeating: "b", count: 32)
        let firstKey = Data(repeating: 0x11, count: 32)
        let secondKey = Data(repeating: 0x22, count: 32)

        try store.replace(with: [
            firstID: firstKey,
            secondID: secondKey,
        ])
        XCTAssertEqual(try store.key(forComputer: firstID), firstKey)
        XCTAssertEqual(try store.key(forComputer: secondID), secondKey)

        try store.replace(with: [secondID: secondKey])
        XCTAssertNil(try store.key(forComputer: firstID))
        XCTAssertEqual(try store.key(forComputer: secondID), secondKey)
    }

    func testFileStoreRejectsInvalidComputerIDsAndKeyLengths() throws {
        let (directory, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try store.replace(with: [
            "not-a-computer-id": Data(repeating: 0x11, count: 32)
        ]))
        XCTAssertThrowsError(try store.replace(with: [
            String(repeating: "a", count: 32): Data(repeating: 0x11, count: 31)
        ]))
    }

    func testFileStoreRejectsCorruptArchives() throws {
        let (directory, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("not-json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.key(
            forComputer: String(repeating: "a", count: 32)
        ))
    }

    func testStoredDerivedKeyDecryptsRemoteAgentEnvelope() throws {
        let (directory, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let computerID = String(repeating: "c", count: 32)
        let key = AgentActivity.activityKey(
            secret: Data(repeating: 0x42, count: 32)
        )
        let keyData = key.withUnsafeBytes { Data($0) }
        let content = AgentActivity.Content(
            id: "agent-1",
            agent: "codex",
            state: .running,
            sessionName: "Keep the island specific",
            message: "Reading the latest agent output",
            updatedAt: 123
        )
        let sealed = try AgentActivity.seal(
            content, key: key, computerID: computerID
        )

        try store.replace(with: [computerID: keyData])
        let storedKey = try XCTUnwrap(store.key(forComputer: computerID))

        XCTAssertEqual(
            try AgentActivity.open(
                sealed,
                key: SymmetricKey(data: storedKey),
                computerID: computerID
            ),
            content
        )
    }

    private func makeStore() throws -> (
        directory: URL, store: AgentActivityKeyFileStore
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pedals-live-activity-keys-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return (
            directory,
            AgentActivityKeyFileStore(fileURL: directory.appendingPathComponent(
                "keys.json", isDirectory: false
            ))
        )
    }
}
