import Darwin
import Foundation

/// A process-independent snapshot transaction backed by an App Group file.
///
/// Every operation opens the same lock file, so app, widget, Watch app, and
/// Watch widget processes all participate in the same sequence comparison.
/// The JSON replacement stays atomic for readers after a crash.
struct StatusSnapshotFileStore: Sendable {
    struct SaveResult: Sendable {
        let snapshot: TTYStatusSnapshot
        let didWrite: Bool
    }

    let directory: URL

    private var lockURL: URL {
        directory.appendingPathComponent("snapshot.lock")
    }

    private var snapshotURL: URL {
        directory.appendingPathComponent("snapshot-v4.json")
    }

    func load() throws -> TTYStatusSnapshot? {
        try withLock { try loadLocked() }
    }

    func save(_ candidate: TTYStatusSnapshot) throws -> SaveResult {
        try withLock {
            if let current = try loadLocked() {
                guard candidate.sequence >= current.sequence else {
                    return SaveResult(snapshot: current, didWrite: false)
                }
                guard candidate != current else {
                    return SaveResult(snapshot: current, didWrite: false)
                }
            }

            let data = try JSONEncoder.ttybuild.encode(candidate)
            try data.write(
                to: snapshotURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return SaveResult(snapshot: candidate, didWrite: true)
        }
    }

    func remove() throws {
        try withLock {
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
            try FileManager.default.removeItem(at: snapshotURL)
        }
    }

    private func loadLocked() throws -> TTYStatusSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder.ttybuild.decode(TTYStatusSnapshot.self, from: data)
    }

    private func withLock<Result>(_ operation: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
