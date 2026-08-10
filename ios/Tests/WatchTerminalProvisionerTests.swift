import Foundation
import TTYBuildKit
import XCTest

@testable import TTYBuild

@MainActor
final class WatchTerminalProvisionerTests: XCTestCase {
    private final class MemoryState {
        var data: Data?
    }

    private final class MockAPI: WatchTerminalServiceClient {
        struct Sync: Equatable {
            let sourceID: String
            let delegateID: String
        }

        var identities: [ClientIdentity]
        var syncErrors: [(any Error)?] = []
        private(set) var createCount = 0
        private(set) var syncs: [Sync] = []

        init(identities: [ClientIdentity]) {
            self.identities = identities
        }

        func createClient() async throws -> ClientIdentity {
            createCount += 1
            return identities.removeFirst()
        }

        func synchronizeBindings(
            from source: ClientIdentity,
            to delegate: ClientIdentity
        ) async throws -> Int {
            syncs.append(.init(sourceID: source.clientID, delegateID: delegate.clientID))
            if !syncErrors.isEmpty, let error = syncErrors.removeFirst() { throw error }
            return 1
        }
    }

    func testCreatesIndependentIdentityAndReusesItForLaterSynchronization() async throws {
        let memory = MemoryState()
        let delegate = try identity("b")
        let api = MockAPI(identities: [delegate])
        let provisioner = makeProvisioner(memory: memory, api: api)
        let source = try identity("a")
        let binding = try computer("1")

        let first = try await provisioner.context(source: source, bindings: [binding])
        let second = try await provisioner.context(source: source, bindings: [binding])

        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(first.bindings, second.bindings)
        XCTAssertEqual(first.identity, delegate)
        XCTAssertNotEqual(first.identity.clientID, source.clientID)
        XCTAssertEqual(api.createCount, 1)
        XCTAssertEqual(api.syncs, [
            .init(sourceID: source.clientID, delegateID: delegate.clientID),
            .init(sourceID: source.clientID, delegateID: delegate.clientID),
        ])
    }

    func testRejectedDelegateIsReplacedAndSynchronizationRetried() async throws {
        let memory = MemoryState()
        memory.data = try JSONEncoder().encode(identity("b"))
        let replacement = try identity("c")
        let api = MockAPI(identities: [replacement])
        api.syncErrors = [
            TTYBuildServiceAPI.APIError.rejected(status: 403, message: "invalid delegate"),
            nil,
        ]
        let provisioner = makeProvisioner(memory: memory, api: api)

        let context = try await provisioner.context(
            source: try identity("a"),
            bindings: [try computer("1")]
        )

        XCTAssertEqual(context.identity, replacement)
        XCTAssertEqual(api.createCount, 1)
        XCTAssertEqual(api.syncs.map(\.delegateID), [repeating("b"), repeating("c")])
        XCTAssertEqual(
            try JSONDecoder().decode(ClientIdentity.self, from: XCTUnwrap(memory.data)),
            replacement
        )
    }

    func testSourceIdentityIsNeverReusedAsWatchIdentity() async throws {
        let memory = MemoryState()
        let source = try identity("a")
        memory.data = try JSONEncoder().encode(source)
        let replacement = try identity("b")
        let api = MockAPI(identities: [replacement])
        let provisioner = makeProvisioner(memory: memory, api: api)

        let context = try await provisioner.context(source: source, bindings: [])

        XCTAssertEqual(context.identity, replacement)
        XCTAssertEqual(api.createCount, 1)
        XCTAssertEqual(api.syncs.map(\.delegateID), [replacement.clientID])
    }

    func testCorruptReplaceableIdentityIsRecovered() async throws {
        let memory = MemoryState()
        memory.data = Data("not-json".utf8)
        let replacement = try identity("b")
        let api = MockAPI(identities: [replacement])
        let provisioner = makeProvisioner(memory: memory, api: api)

        let context = try await provisioner.context(
            source: try identity("a"),
            bindings: []
        )

        XCTAssertEqual(context.identity, replacement)
        XCTAssertEqual(api.createCount, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(ClientIdentity.self, from: XCTUnwrap(memory.data)),
            replacement
        )
    }

    private func makeProvisioner(
        memory: MemoryState,
        api: MockAPI
    ) -> WatchTerminalProvisioner {
        WatchTerminalProvisioner(
            apiFactory: { _ in api },
            stateReader: { memory.data },
            stateWriter: { memory.data = $0 }
        )
    }

    private func identity(_ marker: String) throws -> ClientIdentity {
        let id = repeating(marker)
        return try ClientIdentity(
            serviceURL: URL(string: "https://relay.test")!,
            clientID: id,
            clientToken: "client-\(id)",
            statusToken: "status-\(id)"
        )
    }

    private func computer(_ marker: String) throws -> ComputerBinding {
        try ComputerBinding(
            serviceURL: URL(string: "https://relay.test")!,
            computerID: repeating(marker),
            secret: Data(repeating: 1, count: ComputerBinding.secretByteCount)
        )
    }

    private func repeating(_ marker: String) -> String {
        String(repeating: marker, count: ComputerBinding.computerIDLength)
    }
}
