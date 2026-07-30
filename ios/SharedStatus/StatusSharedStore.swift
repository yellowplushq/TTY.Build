import Darwin
import Foundation
import os

struct PushMutationClaim: Codable, Equatable, Sendable {
    let id: String
    let credentialGeneration: UInt64
    let mutation: PendingPushEndpointMutation
    let expiresAt: Date
}

struct PushMutationRetry: Codable, Equatable, Sendable {
    let mutation: PendingPushEndpointMutation
    let attempt: Int
    let notBefore: Date
}

struct ClaimedPushMutation: Equatable, Sendable {
    let claim: PushMutationClaim
    let credential: PedalsStatusCredential
}

struct PushMutationClaimDecision: Equatable, Sendable {
    let delivery: ClaimedPushMutation?
    let nextAttemptAt: Date?
}

/// Durable delivery queue plus the latest endpoint registrations that should
/// exist for the current client. Successfully delivered PUTs leave a desired
/// registration behind so a replacement client identity can register the
/// same APNs tokens without waiting for WidgetKit/ActivityKit to rotate them.
///
/// Credential, queue, claim lease, and retry state live in one atomic file.
/// Network requests never hold the file lock. A returning request can commit
/// only the exact claim ID and credential generation it acquired, so a request
/// that was in flight during credential rotation cannot remove requeued work.
struct PushMutationState: Codable, Equatable, Sendable {
    var credential: PedalsStatusCredential? = nil
    var credentialGeneration: UInt64 = 0
    var pending: [String: PendingPushEndpointMutation] = [:]
    var desired: [String: PendingPushEndpointMutation] = [:]
    var activeClaim: PushMutationClaim? = nil
    var retries: [String: PushMutationRetry] = [:]
    // WidgetKit may deliver a token before it reports any configured widgets.
    // Keep the latest observation even after queuing the corresponding DELETE;
    // a real timeline request can then restore the PUT without waiting for the
    // system to repeat an unchanged token callback.
    var observedWidgetRegistrations: [String: PushEndpointRegistration]? = nil

    static let claimLease: TimeInterval = 30

    mutating func enqueue(_ mutation: PendingPushEndpointMutation) {
        pending[mutation.identity] = mutation
        retries.removeValue(forKey: mutation.identity)
        switch mutation.operation {
        case .put:
            desired[mutation.identity] = mutation
        case .delete:
            desired.removeValue(forKey: mutation.identity)
        }
    }

    mutating func observeWidgetRegistration(
        _ registration: PushEndpointRegistration,
        hasConfiguredWidgets: Bool
    ) {
        precondition(
            registration.surface == .iOSWidget
                || registration.surface == .watchWidget
        )
        var registrations = observedWidgetRegistrations ?? [:]
        registrations[registration.surface.rawValue] = registration
        observedWidgetRegistrations = registrations
        if hasConfiguredWidgets {
            enqueue(.put(registration))
        } else {
            enqueue(.delete(registration.surface))
        }
    }

    @discardableResult
    mutating func activateObservedWidgetRegistration(_ surface: PushSurface) -> Bool {
        guard surface == .iOSWidget || surface == .watchWidget,
              let registration = observedWidgetRegistrations?[surface.rawValue]
        else { return false }
        let mutation = PendingPushEndpointMutation.put(registration)
        // A successful PUT remains in `desired` after leaving the delivery
        // queue. Timeline refreshes are frequent (including after every Widget
        // APNs), so re-enqueuing the same endpoint here would reset the server's
        // delivery baseline and create an avoidable push/register loop.
        guard desired[mutation.identity] != mutation else { return false }
        enqueue(mutation)
        return true
    }

    mutating func removePending(_ mutation: PendingPushEndpointMutation) {
        guard pending[mutation.identity] == mutation else { return }
        pending.removeValue(forKey: mutation.identity)
        retries.removeValue(forKey: mutation.identity)
    }

    @discardableResult
    mutating func installCredential(_ replacement: PedalsStatusCredential) -> Bool {
        guard credential != replacement else { return false }
        credential = replacement
        credentialGeneration &+= 1
        // DELETEs targeted the previous client. The replacement needs every
        // still-desired endpoint PUT and none of those old deletes. Clearing
        // the claim invalidates any old request that is still in flight.
        pending = desired
        activeClaim = nil
        retries.removeAll()
        return true
    }

    @discardableResult
    mutating func removeCredential() -> Bool {
        guard credential != nil else { return false }
        credential = nil
        credentialGeneration &+= 1
        pending.removeAll()
        activeClaim = nil
        retries.removeAll()
        return true
    }

    mutating func claimNext(
        now: Date,
        lease: TimeInterval = claimLease,
        claimID: String
    ) -> PushMutationClaimDecision {
        guard let credential else {
            return .init(delivery: nil, nextAttemptAt: nil)
        }

        if let claim = activeClaim {
            if claim.expiresAt > now {
                return .init(delivery: nil, nextAttemptAt: claim.expiresAt)
            }
            // The owner may have crashed or been suspended after returning
            // from an extension callback. Expiration makes the work recoverable.
            activeClaim = nil
        }

        let identity = pending.keys.sorted().first { identity in
            guard let retry = retries[identity],
                  retry.mutation == pending[identity]
            else { return true }
            return retry.notBefore <= now
        }
        guard let identity, let mutation = pending[identity] else {
            let nextAttempt = retries.values
                .filter { pending[$0.mutation.identity] == $0.mutation }
                .map(\.notBefore)
                .min()
            return .init(delivery: nil, nextAttemptAt: nextAttempt)
        }

        let claim = PushMutationClaim(
            id: claimID,
            credentialGeneration: credentialGeneration,
            mutation: mutation,
            expiresAt: now.addingTimeInterval(lease)
        )
        activeClaim = claim
        return .init(
            delivery: .init(claim: claim, credential: credential),
            nextAttemptAt: nil
        )
    }

    mutating func complete(_ claim: PushMutationClaim) {
        guard activeClaim?.id == claim.id,
              activeClaim?.credentialGeneration == claim.credentialGeneration
        else { return }
        activeClaim = nil
        guard credentialGeneration == claim.credentialGeneration,
              pending[claim.mutation.identity] == claim.mutation
        else { return }
        pending.removeValue(forKey: claim.mutation.identity)
        retries.removeValue(forKey: claim.mutation.identity)
    }

    @discardableResult
    mutating func fail(_ claim: PushMutationClaim, now: Date) -> Date? {
        guard activeClaim?.id == claim.id,
              activeClaim?.credentialGeneration == claim.credentialGeneration
        else { return nextAttemptAt }
        activeClaim = nil
        guard credentialGeneration == claim.credentialGeneration,
              pending[claim.mutation.identity] == claim.mutation
        else { return nextAttemptAt }

        let previous = retries[claim.mutation.identity]
        let attempt: Int
        if let previous, previous.mutation == claim.mutation {
            attempt = previous.attempt + 1
        } else {
            attempt = 1
        }
        let notBefore = now.addingTimeInterval(Self.retryDelay(forAttempt: attempt))
        retries[claim.mutation.identity] = .init(
            mutation: claim.mutation,
            attempt: attempt,
            notBefore: notBefore
        )
        return nextAttemptAt
    }

    var nextAttemptAt: Date? {
        if let claim = activeClaim { return claim.expiresAt }
        return retries.values
            .filter { pending[$0.mutation.identity] == $0.mutation }
            .map(\.notBefore)
            .min()
    }

    static func retryDelay(forAttempt attempt: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [2, 5, 15, 30, 60, 5 * 60]
        return schedule[min(max(1, attempt), schedule.count) - 1]
    }
}

public enum StatusSharedStore {
    public static let didChange = Notification.Name("air.build.pedals.status.did-change")

    private static let logger = Logger(
        subsystem: "air.build.pedals",
        category: "StatusSharedStore"
    )

    public static func credential() -> PedalsStatusCredential? {
        withPushMutationState { state in
            (state.credential, false)
        } ?? nil
    }

    @discardableResult
    public static func saveCredential(_ credential: PedalsStatusCredential) async -> Bool {
        let changed = await Task.detached(priority: .utility) {
            withPushMutationState { state in
                let changed = state.installCredential(credential)
                return (changed, changed)
            } ?? false
        }.value
        if changed {
            removeSnapshot()
            await MainActor.run {
                NotificationCenter.default.post(name: didChange, object: nil)
            }
        }
        return changed
    }

    public static func removeCredential() {
        let changed = withPushMutationState { state in
            let changed = state.removeCredential()
            return (changed, changed)
        } ?? false
        if changed {
            removeSnapshot()
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    public static func snapshot() -> TTYStatusSnapshot {
        guard let store = snapshotFileStore else { return .empty }
        do {
            return try store.load() ?? .empty
        } catch {
            logger.error("Cannot read shared status snapshot: \(error.localizedDescription)")
            return .empty
        }
    }

    /// Atomically compares and stores `candidate` across every App Group
    /// process, returning the snapshot that actually won the transaction.
    @discardableResult
    public static func saveSnapshot(_ candidate: TTYStatusSnapshot) -> TTYStatusSnapshot {
        guard let store = snapshotFileStore else { return .empty }
        do {
            let result = try store.save(candidate)
            if result.didWrite {
                NotificationCenter.default.post(name: didChange, object: result.snapshot)
            }
            return result.snapshot
        } catch {
            logger.error("Cannot persist shared status snapshot: \(error.localizedDescription)")
            return (try? store.load()) ?? .empty
        }
    }

    private static func removeSnapshot() {
        guard let store = snapshotFileStore else { return }
        do {
            try store.remove()
        } catch {
            logger.error("Cannot remove shared status snapshot: \(error.localizedDescription)")
        }
    }

    private static var snapshotFileStore: StatusSnapshotFileStore? {
        sharedStatusDirectory().map(StatusSnapshotFileStore.init(directory:))
    }

    public static func savePendingPushMutation(_ mutation: PendingPushEndpointMutation) {
        _ = withPushMutationState { state in
            let previous = state
            state.enqueue(mutation)
            return ((), state != previous)
        }
    }

    public static func saveWidgetPushObservation(
        _ registration: PushEndpointRegistration,
        hasConfiguredWidgets: Bool
    ) {
        _ = withPushMutationState { state in
            let previous = state
            state.observeWidgetRegistration(
                registration,
                hasConfiguredWidgets: hasConfiguredWidgets
            )
            return ((), state != previous)
        }
    }

    /// A timeline request is authoritative evidence that this widget is now
    /// configured. It also repairs a missed configuration-change callback from
    /// WidgetKit without registering tokens for widgets that remain removed.
    public static func activateObservedWidgetPushEndpoint(_ surface: PushSurface) {
        _ = withPushMutationState { state in
            let previous = state
            _ = state.activateObservedWidgetRegistration(surface)
            return ((), state != previous)
        }
    }

    static func claimNextPushMutation(
        now: Date = .now,
        claimID: String = UUID().uuidString.lowercased()
    ) -> PushMutationClaimDecision {
        withPushMutationState { state in
            let previous = state
            let decision = state.claimNext(now: now, claimID: claimID)
            return (decision, state != previous)
        } ?? .init(delivery: nil, nextAttemptAt: nil)
    }

    static func completePushMutation(_ claim: PushMutationClaim) {
        _ = withPushMutationState { state in
            let previous = state
            state.complete(claim)
            return ((), state != previous)
        }
    }

    static func failPushMutation(_ claim: PushMutationClaim, now: Date = .now) -> Date? {
        withPushMutationState { state in
            let previous = state
            let nextAttempt = state.fail(claim, now: now)
            return (nextAttempt, state != previous)
        } ?? nil
    }

    /// A short-lived lock plus atomic JSON replacement provides a real claim
    /// and compare-and-commit transaction across the app, widgets, and Watch
    /// extension processes. The caller must never perform network I/O here.
    private static func withPushMutationState<Result>(
        _ body: (inout PushMutationState) -> (Result, Bool)
    ) -> Result? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PedalsStatusConstants.appGroup
        ) else {
            logger.error("App Group unavailable; cannot persist push token mutation")
            return nil
        }
        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PedalsStatus", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            logger.error("Cannot create shared status directory: \(error.localizedDescription)")
            return nil
        }

        let lockURL = directory.appendingPathComponent("push-mutations.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            logger.error("Cannot open shared push mutation lock")
            return nil
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                Darwin.close(descriptor)
                logger.error("Cannot acquire shared push mutation lock")
                return nil
            }
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }

        let fileURL = directory.appendingPathComponent("push-state-v5.json")
        var state = PushMutationState()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                if !data.isEmpty {
                    state = try JSONDecoder.pedals.decode(
                        PushMutationState.self, from: data
                    )
                }
            } catch {
                // Self-heal instead of bricking the queue: a state written
                // by an older build (e.g. a since-renamed surface value)
                // must not block registration forever. The credential is
                // re-installed on the next app launch and every endpoint
                // re-registers from its own token source.
                logger.error(
                    "Resetting undecodable shared push state: \(error.localizedDescription)"
                )
                state = PushMutationState()
            }
        }
        let (result, changed) = body(&state)
        if changed {
            do {
                let data = try JSONEncoder.pedals.encode(state)
                try data.write(
                    to: fileURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            } catch {
                logger.error("Cannot persist push mutation transaction: \(error.localizedDescription)")
                return nil
            }
        }
        return result
    }

    private static func sharedStatusDirectory() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PedalsStatusConstants.appGroup
        ) else {
            logger.error("App Group unavailable; cannot open shared status directory")
            return nil
        }
        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("PedalsStatus", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            return directory
        } catch {
            logger.error("Cannot create shared status directory: \(error.localizedDescription)")
            return nil
        }
    }

}

extension JSONEncoder {
    static var pedals: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var pedals: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Data {
    public var pedalsHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
