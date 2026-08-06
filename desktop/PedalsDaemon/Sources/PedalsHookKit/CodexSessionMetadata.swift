import Foundation
import SQLite3

/// Resolves the user-facing title of a Codex thread from Codex's own local
/// metadata. Reads are short, best-effort, and strictly read-only: hook
/// reporting must never delay or mutate the Codex session.
public enum CodexSessionMetadata {
    public struct Snapshot: Equatable, Sendable {
        public var title: String? = nil
        public var transcriptPath: String? = nil
        /// Whether Codex records this session in its own `threads` table.
        /// `false` means the state database was readable and has no row —
        /// an ephemeral thread (ambient suggestions and similar background
        /// runs) that Codex itself does not treat as a session. `nil` means
        /// the database was unavailable, so nothing can be concluded.
        public var threadRecorded: Bool? = nil

        public init(
            title: String? = nil, transcriptPath: String? = nil,
            threadRecorded: Bool? = nil
        ) {
            self.title = title
            self.transcriptPath = transcriptPath
            self.threadRecorded = threadRecorded
        }
    }

    private static let indexReadLimit: UInt64 = 1_048_576

    public static func title(
        sessionID: String, home explicitHome: URL? = nil
    ) -> String? {
        resolve(sessionID: sessionID, home: explicitHome).title
    }

    public static func resolve(
        sessionID: String, home explicitHome: URL? = nil
    ) -> Snapshot {
        guard !sessionID.isEmpty else { return Snapshot() }
        let home = explicitHome ?? defaultHome
        let row = databaseRow(sessionID: sessionID, home: home)
        return Snapshot(
            title: titleFromIndex(sessionID: sessionID, home: home) ?? row?.title,
            transcriptPath: row?.transcriptPath,
            threadRecorded: row.map(\.recorded)
        )
    }

    private static var defaultHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// `session_index.jsonl` is the source of explicit user-renamed threads.
    /// Scan newest-to-oldest because the index may retain older names.
    private static func titleFromIndex(sessionID: String, home: URL) -> String? {
        let url = home.appendingPathComponent("session_index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let length = try? handle.seekToEnd() else { return nil }
        let offset = length > indexReadLimit ? length - indexReadLimit : 0
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.readToEnd(), !data.isEmpty else { return nil }
            if offset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(...firstNewline)
            }
            for line in data.split(separator: 0x0A).reversed() {
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any],
                    object["id"] as? String == sessionID,
                    let name = object["thread_name"] as? String,
                    let cleaned = cleanedTitle(name)
                else { continue }
                return cleaned
            }
        } catch {
            return nil
        }
        return nil
    }

    private struct DatabaseRow {
        var title: String?
        var transcriptPath: String?
        /// False when the query ran cleanly and found no row: Codex does not
        /// record the session (an ephemeral thread). Any open/prepare/step
        /// failure yields no DatabaseRow at all, never a false negative.
        var recorded: Bool
    }

    /// Newer Codex builds keep the generated title, first message, and
    /// rollout path in `state_5.sqlite`. Open with SQLITE_OPEN_READONLY so
    /// Pedals cannot create, migrate, or otherwise alter Codex state.
    private static func databaseRow(sessionID: String, home: URL) -> DatabaseRow? {
        queryDatabase(sessionID: sessionID, home: home) { database in
            var statement: OpaquePointer?
            let sql = """
            SELECT name, title, first_user_message, preview, rollout_path
            FROM threads WHERE id = ? LIMIT 1
            """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else { return nil }
            defer { sqlite3_finalize(statement) }

            guard bind(sessionID: sessionID, to: statement) else { return nil }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var row = DatabaseRow(recorded: true)
                for column in 0..<4 where row.title == nil {
                    guard let bytes = sqlite3_column_text(statement, Int32(column))
                    else { continue }
                    row.title = cleanedTitle(String(cString: bytes))
                }
                if let bytes = sqlite3_column_text(statement, 4) {
                    let path = sanitizeHookText(
                        String(cString: bytes), cap: HookFieldCaps.transcriptPath
                    )
                    if !path.isEmpty { row.transcriptPath = path }
                }
                return row
            case SQLITE_DONE:
                return DatabaseRow(recorded: false)
            default:
                return nil
            }
        }
    }

    private static func queryDatabase<T>(
        sessionID: String, home: URL,
        _ body: (OpaquePointer) -> T?
    ) -> T? {
        let path = home.appendingPathComponent("state_5.sqlite").path
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
        ) == SQLITE_OK, let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 50)
        return body(database)
    }

    private static func bind(sessionID: String, to statement: OpaquePointer) -> Bool {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        return sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK
    }

    private static func cleanedTitle(_ value: String) -> String? {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return sanitizeHookText(normalized, cap: HookFieldCaps.sessionName)
    }
}
