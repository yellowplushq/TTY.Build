import Foundation
import SQLite3
import XCTest

@testable import TTYBuildHookKit

/// Codex state-database resolution: titles, rollout paths, and the
/// ephemeral-thread discriminator (`threadRecorded`).
final class CodexSessionMetadataTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func makeStateDatabase(rows: [(id: String, title: String, rollout: String)]) throws {
        let path = home.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY, name TEXT, title TEXT,
            first_user_message TEXT NOT NULL DEFAULT '',
            preview TEXT NOT NULL DEFAULT '', rollout_path TEXT NOT NULL
        )
        """, nil, nil, nil), SQLITE_OK)
        for row in rows {
            let sql = """
            INSERT INTO threads (id, title, rollout_path)
            VALUES ('\(row.id)', '\(row.title)', '\(row.rollout)')
            """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    func testRecordedThreadResolvesTitleRolloutAndRecordedFlag() throws {
        try makeStateDatabase(rows: [
            (id: "thread-1", title: "Fix the relay", rollout: "/tmp/rollout.jsonl")
        ])
        let snapshot = CodexSessionMetadata.resolve(sessionID: "thread-1", home: home)
        XCTAssertEqual(snapshot.title, "Fix the relay")
        XCTAssertEqual(snapshot.transcriptPath, "/tmp/rollout.jsonl")
        XCTAssertEqual(snapshot.threadRecorded, true)
    }

    func testEphemeralThreadIsReportedAsUnrecorded() throws {
        try makeStateDatabase(rows: [
            (id: "thread-1", title: "Fix the relay", rollout: "/tmp/rollout.jsonl")
        ])
        let snapshot = CodexSessionMetadata.resolve(
            sessionID: "ambient-suggestions-run", home: home
        )
        XCTAssertEqual(
            snapshot.threadRecorded, false,
            "a readable database without a row marks the thread ephemeral"
        )
        XCTAssertNil(snapshot.title)
        XCTAssertNil(snapshot.transcriptPath)
    }

    func testMissingDatabaseConcludesNothing() {
        let snapshot = CodexSessionMetadata.resolve(sessionID: "thread-1", home: home)
        XCTAssertNil(snapshot.threadRecorded, "no database means no verdict")
    }

    func testMalformedDatabaseConcludesNothing() throws {
        try Data("not a sqlite file".utf8).write(
            to: home.appendingPathComponent("state_5.sqlite")
        )
        let snapshot = CodexSessionMetadata.resolve(sessionID: "thread-1", home: home)
        XCTAssertNil(snapshot.threadRecorded)
    }
}
