import Foundation
import TTYBuildKit

/// Arbitrates the exclusive interactive holder of each session
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §2). Only the holder's `stdin` and
/// `resize` are applied — this class is the enforcement point; placeholders
/// on non-holding surfaces are cosmetic on top of it.
///
/// Rules: a claim is unconditional and last-writer-wins; the initial holder
/// is the creator; an attach connection's disconnect releases its holds, a
/// relay client's disconnect does not (a stale holder blocks nobody).
public final class AttachArbiter: @unchecked Sendable {
    /// An interactive source, compared against the session's holder.
    public enum Source: Equatable, Sendable {
        /// One local attach connection on the control socket. Each attach
        /// process is its own holder: two terminals on the same session are
        /// exclusive against each other, not just against the phone.
        case attach(connectionID: UInt64)
        /// A bound relay client's authenticated principal (iPhone, or the
        /// Watch's delegate identity).
        case client(principal: String)
    }

    private struct Holder {
        var source: Source
        var name: String?
    }

    public typealias Observer = @Sendable (Int, HolderInfo) -> Void

    private let lock = NSLock()
    private var holders: [Int: Holder] = [:]
    private var observers: [UUID: Observer] = [:]

    public init() {}

    /// Registers a holder-change observer, called outside the lock with the
    /// session id and the wire form of its holder. A claim notifies even
    /// when the holder is unchanged, so a claimant always observes a
    /// `takeover` answering it. Observers: the relay host (broadcasts
    /// `takeover` to clients) and each attach connection (placeholder flip).
    @discardableResult
    public func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = observer }
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.withLock { _ = observers.removeValue(forKey: token) }
    }

    /// Unconditional last-writer-wins claim.
    public func claim(sessionId: Int, source: Source, name: String? = nil) {
        let (callbacks, info): ([Observer], HolderInfo) = lock.withLock {
            let holder = Holder(source: source, name: name)
            holders[sessionId] = holder
            return (Array(observers.values), Self.info(holder))
        }
        for callback in callbacks { callback(sessionId, info) }
    }

    /// True iff `source` currently holds the session. An unheld session
    /// (`none`) accepts input from nobody — claiming is how any surface
    /// becomes interactive.
    public func isHolder(sessionId: Int, source: Source) -> Bool {
        lock.withLock { holders[sessionId]?.source == source }
    }

    public func holderInfo(sessionId: Int) -> HolderInfo {
        lock.withLock { Self.info(holders[sessionId]) }
    }

    /// Wire snapshot for the post-`sessions` hello replay, sorted by id.
    /// Only sessions with a live holder entry are included: `none` is the
    /// implicit default for anything unlisted.
    public func snapshot() -> [(sessionId: Int, holder: HolderInfo)] {
        lock.withLock {
            holders.sorted { $0.key < $1.key }
                .map { ($0.key, Self.info($0.value)) }
        }
    }

    /// Releases every session held by one attach connection (socket close /
    /// process death). Broadcasts `none` for each so placeholders flip to
    /// "tap to attach".
    public func releaseAll(attachConnectionID id: UInt64) {
        let (callbacks, released): ([Observer], [Int]) = lock.withLock {
            let ids = holders.filter { $0.value.source == .attach(connectionID: id) }
                .map(\.key)
            for sessionId in ids { holders.removeValue(forKey: sessionId) }
            return (Array(observers.values), ids.sorted())
        }
        for sessionId in released {
            for callback in callbacks {
                callback(sessionId, HolderInfo(kind: .none))
            }
        }
    }

    /// Releases one session if `source` still holds it (attach detach key).
    public func release(sessionId: Int, ifHolder source: Source) {
        let callbacks: [Observer] = lock.withLock {
            guard holders[sessionId]?.source == source else { return [] }
            holders.removeValue(forKey: sessionId)
            return Array(observers.values)
        }
        for callback in callbacks { callback(sessionId, HolderInfo(kind: .none)) }
    }

    /// Drops the holder of an exited session, broadcasting `none` (the exit
    /// presentation wins over any placeholder on both surfaces).
    public func sessionExited(sessionId: Int) {
        let callbacks: [Observer] = lock.withLock {
            guard holders.removeValue(forKey: sessionId) != nil else { return [] }
            return Array(observers.values)
        }
        for callback in callbacks { callback(sessionId, HolderInfo(kind: .none)) }
    }

    /// Drops holders of sessions no longer in the directory (closed). No
    /// broadcast: the session row itself is gone from every client.
    public func retainSessions(ids: Set<Int>) {
        lock.withLock {
            holders = holders.filter { ids.contains($0.key) }
        }
    }

    private static func info(_ holder: Holder?) -> HolderInfo {
        guard let holder else { return HolderInfo(kind: .none) }
        switch holder.source {
        case .attach(let connectionID):
            // The synthesized principal lets an attach client tell "I hold"
            // from "another terminal holds" (its own id arrives in the attach
            // handshake). Clients only compare it against their own identity.
            return HolderInfo(
                kind: .attach,
                principal: "attach:\(connectionID)",
                name: holder.name
            )
        case .client(let principal):
            return HolderInfo(kind: .client, principal: principal, name: holder.name)
        }
    }
}
