import TTYBuildKit
import XCTest

@testable import TTYBuildDaemonCore

final class AttachArbiterTests: XCTestCase {
    private let phone = AttachArbiter.Source.client(
        principal: "fedcba9876543210fedcba9876543210"
    )
    private let watch = AttachArbiter.Source.client(
        principal: "0123456789abcdef0123456789abcdef"
    )
    private let terminal = AttachArbiter.Source.attach(connectionID: 1)

    /// Serialized record of observer callbacks for assertion.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(Int, HolderInfo)] = []

        func append(_ sessionId: Int, _ holder: HolderInfo) {
            lock.withLock { entries.append((sessionId, holder)) }
        }

        var all: [(Int, HolderInfo)] { lock.withLock { entries } }
    }

    func testUnheldSessionAcceptsInputFromNobody() {
        let arbiter = AttachArbiter()
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: terminal))
        XCTAssertEqual(arbiter.holderInfo(sessionId: 1), HolderInfo(kind: .none))
    }

    func testClaimIsExclusiveAndLastWriterWins() {
        let arbiter = AttachArbiter()
        arbiter.claim(sessionId: 1, source: phone)
        XCTAssertTrue(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: watch))

        arbiter.claim(sessionId: 1, source: terminal, name: "iTerm2")
        XCTAssertTrue(arbiter.isHolder(sessionId: 1, source: terminal))
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertEqual(
            arbiter.holderInfo(sessionId: 1),
            HolderInfo(kind: .attach, principal: "attach:1", name: "iTerm2")
        )
    }

    func testHolderIsPerSession() {
        let arbiter = AttachArbiter()
        arbiter.claim(sessionId: 1, source: phone)
        arbiter.claim(sessionId: 2, source: terminal)
        XCTAssertTrue(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertFalse(arbiter.isHolder(sessionId: 2, source: phone))
        XCTAssertTrue(arbiter.isHolder(sessionId: 2, source: terminal))
    }

    func testClaimNotifiesEvenWhenHolderUnchanged() {
        let arbiter = AttachArbiter()
        let log = Log()
        arbiter.addObserver { log.append($0, $1) }
        arbiter.claim(sessionId: 3, source: phone)
        arbiter.claim(sessionId: 3, source: phone)
        XCTAssertEqual(log.all.count, 2, "a claimant must always observe an answer")
        XCTAssertEqual(log.all.last?.0, 3)
        XCTAssertEqual(log.all.last?.1.kind, .client)
    }

    func testClientHolderInfoCarriesPrincipal() {
        let arbiter = AttachArbiter()
        arbiter.claim(sessionId: 1, source: phone)
        let info = arbiter.holderInfo(sessionId: 1)
        XCTAssertEqual(info.kind, .client)
        XCTAssertEqual(info.principal, "fedcba9876543210fedcba9876543210")
    }

    func testReleaseIfHolderOnlyReleasesTheHolder() {
        let arbiter = AttachArbiter()
        let log = Log()
        arbiter.claim(sessionId: 1, source: phone)
        arbiter.addObserver { log.append($0, $1) }

        arbiter.release(sessionId: 1, ifHolder: terminal)
        XCTAssertTrue(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertTrue(log.all.isEmpty, "a non-holder release must not broadcast")

        arbiter.release(sessionId: 1, ifHolder: phone)
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertEqual(log.all.count, 1)
        XCTAssertEqual(log.all.last?.1.kind, HolderInfo.Kind.none)
    }

    func testAttachDisconnectReleasesAllItsSessionsAndBroadcastsNone() {
        let arbiter = AttachArbiter()
        let log = Log()
        arbiter.claim(sessionId: 1, source: terminal)
        arbiter.claim(sessionId: 2, source: terminal)
        arbiter.claim(sessionId: 3, source: phone)
        arbiter.addObserver { log.append($0, $1) }

        arbiter.releaseAll(attachConnectionID: 1)
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: terminal))
        XCTAssertFalse(arbiter.isHolder(sessionId: 2, source: terminal))
        XCTAssertTrue(
            arbiter.isHolder(sessionId: 3, source: phone),
            "client holders survive an attach disconnect"
        )
        XCTAssertEqual(log.all.map(\.0), [1, 2])
        XCTAssertTrue(log.all.allSatisfy { $0.1.kind == .none })
    }

    func testSessionExitDropsHolderAndBroadcastsOnce() {
        let arbiter = AttachArbiter()
        let log = Log()
        arbiter.claim(sessionId: 5, source: phone)
        arbiter.addObserver { log.append($0, $1) }

        arbiter.sessionExited(sessionId: 5)
        arbiter.sessionExited(sessionId: 5)
        XCTAssertEqual(log.all.count, 1, "an already-unheld exit must not rebroadcast")
        XCTAssertEqual(log.all.first?.0, 5)
        XCTAssertEqual(log.all.first?.1.kind, HolderInfo.Kind.none)
    }

    func testRetainSessionsDropsClosedHoldersSilently() {
        let arbiter = AttachArbiter()
        let log = Log()
        arbiter.claim(sessionId: 1, source: phone)
        arbiter.claim(sessionId: 2, source: terminal)
        arbiter.addObserver { log.append($0, $1) }

        arbiter.retainSessions(ids: [2])
        XCTAssertFalse(arbiter.isHolder(sessionId: 1, source: phone))
        XCTAssertTrue(arbiter.isHolder(sessionId: 2, source: terminal))
        XCTAssertTrue(log.all.isEmpty, "closed sessions vanish without a broadcast")
    }

    func testSnapshotListsHeldSessionsSortedById() {
        let arbiter = AttachArbiter()
        arbiter.claim(sessionId: 9, source: phone)
        arbiter.claim(sessionId: 2, source: terminal, name: "iTerm2")
        let snapshot = arbiter.snapshot()
        XCTAssertEqual(snapshot.map(\.sessionId), [2, 9])
        XCTAssertEqual(snapshot[0].holder.kind, .attach)
        XCTAssertEqual(snapshot[0].holder.name, "iTerm2")
        XCTAssertEqual(snapshot[1].holder.kind, .client)
    }

    func testRemovedObserverStopsReceiving() {
        let arbiter = AttachArbiter()
        let log = Log()
        let token = arbiter.addObserver { log.append($0, $1) }
        arbiter.claim(sessionId: 1, source: phone)
        arbiter.removeObserver(token)
        arbiter.claim(sessionId: 1, source: terminal)
        XCTAssertEqual(log.all.count, 1)
    }
}
