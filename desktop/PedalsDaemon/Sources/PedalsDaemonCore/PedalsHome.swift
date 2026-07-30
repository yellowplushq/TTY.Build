import Darwin
import Foundation
import PedalsKit

/// `~/.pedals` — v2 service config, host identity, and control-socket paths.
/// The directory can be overridden with the `PEDALS_HOME` environment variable
/// (used by tests and by CI to avoid touching the real home directory).
public struct PedalsHome: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["PEDALS_HOME"],
                  !override.isEmpty {
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pedals", isDirectory: true)
        }
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var identityURL: URL { directory.appendingPathComponent("identity.json") }
    public var identityLockURL: URL { directory.appendingPathComponent("identity.lock") }
    public var socketPath: String { directory.appendingPathComponent("pedals.sock").path }
    public var sessionCounterURL: URL { directory.appendingPathComponent("session-counter") }
    /// Binaries shipped into the home directory (the pedals-hook reporter),
    /// so installed hooks survive daemon rebuilds and relocations.
    public var binDirectory: URL { directory.appendingPathComponent("bin", isDirectory: true) }
    public var hookReporterURL: URL { binDirectory.appendingPathComponent("pedals-hook") }

    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - config.json

    /// `{"service": "https://..."}` — REST and authenticated relay origin.
    public struct Config: Codable, Sendable {
        public var service: String

        public init(service: String) { self.service = service }
    }

    public func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    public func save(config: Config) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: - session-counter

    /// Highest session id ever allocated, persisted so a restarted daemon never
    /// reuses a sid: session-channel keys are derived from (secret, sid), and a
    /// reused sid would let a recording relay replay old ciphertext into a new
    /// session (PROTOCOL.md §3).
    public func loadSessionCounter() -> Int? {
        guard let text = try? String(contentsOf: sessionCounterURL, encoding: .utf8)
        else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func save(sessionCounter: Int) throws {
        try ensureDirectoryExists()
        try Data("\(sessionCounter)\n".utf8).write(
            to: sessionCounterURL, options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: sessionCounterURL.path
        )
    }

    // MARK: - identity.json (mode 0600)

    /// Strict read. Only a genuinely absent file means "not registered";
    /// corrupt or unreadable identity data must never be overwritten by a new
    /// remote registration because that would strand the old credential.
    public func loadIdentity() throws -> HostIdentity? {
        do {
            let data = try Data(contentsOf: identityURL)
            let decoded = try JSONDecoder().decode(HostIdentity.self, from: data)
            guard !decoded.hostToken.isEmpty,
                  let computer = try? ComputerBinding(
                      serviceURL: decoded.computer.serviceURL,
                      computerID: decoded.computer.computerID,
                      secret: decoded.computer.secret
                  )
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "invalid host identity")
                )
            }
            return HostIdentity(computer: computer, hostToken: decoded.hostToken)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func save(identity: HostIdentity) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(identity).write(to: identityURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: identityURL.path
        )
    }

    // MARK: - identity.lock

    /// Acquires the cross-process identity mutation lock. Daemon startup keeps
    /// this handle until its control socket is listening, closing the fallback
    /// check-to-mutation race in `pedals pair`.
    public func acquireIdentityLock() throws -> IdentityFileLock {
        try ensureDirectoryExists()
        let descriptor = open(identityLockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        guard fchmod(descriptor, 0o600) == 0 else {
            let error = posixError()
            close(descriptor)
            throw error
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let error = posixError()
            close(descriptor)
            throw error
        }
        return IdentityFileLock(descriptor: descriptor)
    }

    public func withIdentityLock<Value>(_ body: () throws -> Value) throws -> Value {
        let lock = try acquireIdentityLock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class IdentityFileLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func unlock() {
        stateLock.withLock {
            guard let descriptor else { return }
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            self.descriptor = nil
        }
    }

    deinit { unlock() }
}

private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
