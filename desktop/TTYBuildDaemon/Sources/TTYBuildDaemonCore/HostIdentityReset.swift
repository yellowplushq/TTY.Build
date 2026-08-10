import Foundation
import TTYBuildKit

/// Durable reset journal. While it exists, a daemon must not use identity.json.
/// This makes the irreversible remote delete and the local replacement commit
/// recoverable across an error or process restart.
public struct HostIdentityResetState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case revoking
        case revoked
        case replacementCreated
    }

    public var phase: Phase
    public let previous: HostIdentity
    public let replacementServiceURL: URL
    public var replacement: HostIdentity?

    public init(
        phase: Phase,
        previous: HostIdentity,
        replacementServiceURL: URL,
        replacement: HostIdentity? = nil
    ) {
        self.phase = phase
        self.previous = previous
        self.replacementServiceURL = replacementServiceURL
        self.replacement = replacement
    }
}

public enum HostIdentityResetError: Error, CustomStringConvertible, Equatable {
    case corruptJournal
    case noServiceConfigured
    case resetPending(HostIdentityResetState.Phase)
    case identityChanged
    case replacementServiceChanged(expected: URL, requested: URL)
    case revocationFailed(String)
    case revocationRollbackFailed(revocation: String, rollback: String)
    case journalCommitFailed(String)
    case replacementRegistrationFailed(String)
    case replacementJournalFailed(String)
    case replacementCleanupFailed(journal: String, cleanup: String)
    case replacementCommitFailed(String)
    case finalizationFailed(String)
    case registrationCommitFailed(String)
    case registrationCleanupFailed(commit: String, cleanup: String)

    public var description: String {
        switch self {
        case .corruptJournal:
            "identity reset journal is corrupt; refusing to use identity.json"
        case .noServiceConfigured:
            "no service configured — pass --service https://<host> once"
        case .resetPending(let phase):
            "identity reset is incomplete (\(phase.rawValue)); run `ttybuild pair --reset` to resume"
        case .identityChanged:
            "host identity changed while waiting for the identity lock; retry pairing"
        case .replacementServiceChanged(let expected, let requested):
            "identity reset is already targeting \(expected.absoluteString), not \(requested.absoluteString)"
        case .revocationFailed(let detail):
            "old computer revocation failed; local identity was preserved: \(detail)"
        case .revocationRollbackFailed(let revocation, let rollback):
            "old computer revocation failed (\(revocation)); could not clear the local reset journal (\(rollback))"
        case .journalCommitFailed(let detail):
            "old computer was revoked, but the local reset journal could not advance: \(detail)"
        case .replacementRegistrationFailed(let detail):
            "old computer is revoked; replacement registration failed: \(detail). Run `ttybuild pair --reset` to resume"
        case .replacementJournalFailed(let detail):
            "replacement was registered, but its recovery journal could not be saved: \(detail)"
        case .replacementCleanupFailed(let journal, let cleanup):
            "replacement recovery journal failed (\(journal)) and the uncommitted replacement could not be revoked (\(cleanup))"
        case .replacementCommitFailed(let detail):
            "replacement is registered but could not be saved locally: \(detail). Run `ttybuild pair --reset` to resume"
        case .finalizationFailed(let detail):
            "replacement was saved, but reset finalization failed: \(detail). Run `ttybuild pair --reset` to resume"
        case .registrationCommitFailed(let detail):
            "computer registration could not be saved locally: \(detail)"
        case .registrationCleanupFailed(let commit, let cleanup):
            "computer registration could not be saved (\(commit)) and the uncommitted computer could not be revoked (\(cleanup))"
        }
    }
}

public extension TTYBuildHome {
    var identityResetURL: URL { directory.appendingPathComponent("identity-reset.json") }

    /// Strict read: a corrupt journal is a fail-closed condition, never "no reset".
    func loadIdentityResetState() throws -> HostIdentityResetState? {
        do {
            let data = try Data(contentsOf: identityResetURL)
            guard let state = try? JSONDecoder().decode(HostIdentityResetState.self, from: data),
                  (state.phase == .replacementCreated) == (state.replacement != nil),
                  validHostIdentity(state.previous),
                  state.replacement.map(validHostIdentity) ?? true,
                  state.replacement == nil
                    || state.replacement?.computer.serviceURL == state.replacementServiceURL
            else { throw HostIdentityResetError.corruptJournal }
            return state
        } catch let error as HostIdentityResetError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(identityResetState state: HostIdentityResetState) throws {
        try ensureDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: identityResetURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: identityResetURL.path
        )
    }

    func clearIdentityResetState() throws {
        do {
            try FileManager.default.removeItem(at: identityResetURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

private func validHostIdentity(_ identity: HostIdentity) -> Bool {
    !identity.hostToken.isEmpty
        && (try? ComputerBinding(
            serviceURL: identity.computer.serviceURL,
            computerID: identity.computer.computerID,
            secret: identity.computer.secret
        )) != nil
}

/// Registers an identity without leaving an untracked remote credential when
/// the local commit fails.
public func registerHostIdentity(
    home: TTYBuildHome,
    serviceURL: URL,
    actions: ServiceActions
) throws -> HostIdentity {
    try home.withIdentityLock {
        if let pending = try home.loadIdentityResetState() {
            throw HostIdentityResetError.resetPending(pending.phase)
        }
        if let existing = try home.loadIdentity() { return existing }
        return try registerHostIdentityLocked(
            home: home, serviceURL: serviceURL, actions: actions
        )
    }
}

func registerHostIdentityLocked(
    home: TTYBuildHome,
    serviceURL: URL,
    actions: ServiceActions
) throws -> HostIdentity {
    let fresh = try actions.createComputer(serviceURL)
    do {
        try home.save(identity: fresh)
    } catch {
        let commit = String(describing: error)
        do {
            try actions.deleteComputer(fresh)
        } catch {
            throw HostIdentityResetError.registrationCleanupFailed(
                commit: commit, cleanup: String(describing: error)
            )
        }
        throw HostIdentityResetError.registrationCommitFailed(commit)
    }
    return fresh
}

/// Revokes the previous host first, then registers and atomically commits a
/// replacement. `onRevoked` lets a running daemon tear down links that still
/// hold the now-deleted credential.
public func resetHostIdentity(
    home: TTYBuildHome,
    previous: HostIdentity,
    replacementServiceURL: URL,
    actions: ServiceActions,
    onRevoked: () -> Void = {}
) throws -> HostIdentity {
    try home.withIdentityLock {
        if try home.loadIdentityResetState() == nil {
            guard try home.loadIdentity() == previous else {
                throw HostIdentityResetError.identityChanged
            }
        }
        return try resetHostIdentityLocked(
            home: home,
            previous: previous,
            replacementServiceURL: replacementServiceURL,
            actions: actions,
            onRevoked: onRevoked
        )
    }
}

func resetHostIdentityLocked(
    home: TTYBuildHome,
    previous: HostIdentity,
    replacementServiceURL: URL,
    actions: ServiceActions,
    onRevoked: () -> Void = {}
) throws -> HostIdentity {
    var state: HostIdentityResetState
    if let pending = try home.loadIdentityResetState() {
        guard pending.previous == previous else {
            throw HostIdentityResetError.resetPending(pending.phase)
        }
        guard pending.replacementServiceURL == replacementServiceURL else {
            throw HostIdentityResetError.replacementServiceChanged(
                expected: pending.replacementServiceURL,
                requested: replacementServiceURL
            )
        }
        state = pending
    } else {
        state = HostIdentityResetState(
            phase: .revoking,
            previous: previous,
            replacementServiceURL: replacementServiceURL
        )
        try home.save(identityResetState: state)
    }

    if state.phase == .revoking {
        do {
            try actions.deleteComputer(state.previous)
        } catch {
            let revocation = String(describing: error)
            do {
                try home.clearIdentityResetState()
            } catch {
                throw HostIdentityResetError.revocationRollbackFailed(
                    revocation: revocation, rollback: String(describing: error)
                )
            }
            throw HostIdentityResetError.revocationFailed(revocation)
        }
        onRevoked()
        state.phase = .revoked
        do {
            try home.save(identityResetState: state)
        } catch {
            throw HostIdentityResetError.journalCommitFailed(String(describing: error))
        }
    } else {
        onRevoked()
    }

    if state.phase == .revoked {
        let fresh: HostIdentity
        do {
            fresh = try actions.createComputer(state.replacementServiceURL)
        } catch {
            throw HostIdentityResetError.replacementRegistrationFailed(
                String(describing: error)
            )
        }
        state.phase = .replacementCreated
        state.replacement = fresh
        do {
            try home.save(identityResetState: state)
        } catch {
            let journal = String(describing: error)
            do {
                try actions.deleteComputer(fresh)
            } catch {
                throw HostIdentityResetError.replacementCleanupFailed(
                    journal: journal, cleanup: String(describing: error)
                )
            }
            throw HostIdentityResetError.replacementJournalFailed(journal)
        }
    }

    let replacement = state.replacement!
    do {
        try home.save(identity: replacement)
    } catch {
        throw HostIdentityResetError.replacementCommitFailed(String(describing: error))
    }
    do {
        try home.clearIdentityResetState()
    } catch {
        throw HostIdentityResetError.finalizationFailed(String(describing: error))
    }
    return replacement
}
