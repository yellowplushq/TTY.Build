import Foundation
import PedalsKit
import XCTest

@testable import Pedals

@MainActor
final class PairingStoreRecoveryTests: XCTestCase {
    private enum StorageFailure: Error { case write }
    private enum RollbackFailure: Error { case unavailable }

    private final class MemoryState {
        var data: Data?
        var failNextWrite = false

        func read() -> Data? { data }

        func write(_ candidate: Data) throws {
            if failNextWrite {
                failNextWrite = false
                throw StorageFailure.write
            }
            data = candidate
        }
    }

    private final class MockAPI: PairingServiceClient {
        struct BindCall: Equatable {
            let computerID: String
            let clientID: String
        }

        struct ReconcileCall: Equatable {
            let computerIDs: [String]
            let clientID: String
        }

        var identities: [ClientIdentity]
        var bindErrors: [(any Error)?] = []
        var reconcileError: (any Error)?
        private(set) var createCalls = 0
        private(set) var bindCalls: [BindCall] = []
        private(set) var reconcileCalls: [ReconcileCall] = []

        init(identities: [ClientIdentity]) {
            self.identities = identities
        }

        func createClient() async throws -> ClientIdentity {
            createCalls += 1
            guard !identities.isEmpty else {
                throw PedalsServiceAPI.APIError.invalidResponse
            }
            return identities.removeFirst()
        }

        func pair(code: PairingCode, as client: ClientIdentity) async throws -> ComputerBinding {
            let marker = try XCTUnwrap(code.digits.first)
            let computerID = String(
                repeating: String(marker),
                count: ComputerBinding.computerIDLength
            )
            bindCalls.append(.init(
                computerID: computerID,
                clientID: client.clientID
            ))
            // Let a concurrently submitted code enter PairingStore's FIFO
            // gate while the first remote mutation is suspended.
            await Task.yield()
            if !bindErrors.isEmpty, let error = bindErrors.removeFirst() {
                throw error
            }
            return try ComputerBinding(
                serviceURL: client.serviceURL,
                computerID: computerID,
                secret: Data(
                    repeating: UInt8(String(marker)) ?? 0,
                    count: ComputerBinding.secretByteCount
                )
            )
        }

        func reconcileBindings(
            computerIDs: [String],
            as client: ClientIdentity
        ) async throws -> [String] {
            reconcileCalls.append(.init(
                computerIDs: computerIDs,
                clientID: client.clientID
            ))
            if let reconcileError { throw reconcileError }
            return computerIDs
        }
    }

    func testUnauthorizedIdentityIsReplacedAndOldBindingsAreDropped() async throws {
        let fixture = try await seededFixture()
        fixture.api.bindErrors = [unauthorized(), nil]

        let second = try pairingCode("2")
        let result = try await fixture.store.bind(code: second, serviceURL: serviceURL)

        XCTAssertEqual(result.1.clientID, replacementClientID)
        XCTAssertEqual(try fixture.store.loadClientIdentity()?.clientID, replacementClientID)
        XCTAssertEqual(try fixture.store.loadAll().map(\.computerID), [repeating("2")])
        XCTAssertEqual(fixture.api.createCalls, 2)
        XCTAssertEqual(fixture.api.bindCalls.map(\.clientID), [
            oldClientID, oldClientID, replacementClientID,
        ])
        XCTAssertEqual(fixture.api.reconcileCalls, [])
    }

    func testOnlyUnauthorizedTriggersIdentityRecovery() async throws {
        let errors: [any Error] = [
            PedalsServiceAPI.APIError.rejected(status: 400, message: "bad code"),
            PedalsServiceAPI.APIError.rejected(status: 403, message: "forbidden"),
            PedalsServiceAPI.APIError.rejected(status: 500, message: "server error"),
            URLError(.cannotConnectToHost),
        ]

        for error in errors {
            let fixture = try await seededFixture()
            fixture.api.bindErrors = [error]
            do {
                _ = try await fixture.store.bind(
                    code: pairingCode("2"), serviceURL: serviceURL
                )
                XCTFail("Expected \(error) to fail")
            } catch {}

            XCTAssertEqual(fixture.api.createCalls, 1)
            XCTAssertEqual(try fixture.store.loadClientIdentity()?.clientID, oldClientID)
            XCTAssertEqual(try fixture.store.loadAll().map(\.computerID), [repeating("1")])
        }
    }

    func testFailedUnauthorizedRetryPreservesOldState() async throws {
        let fixture = try await seededFixture()
        fixture.api.bindErrors = [
            unauthorized(),
            PedalsServiceAPI.APIError.rejected(status: 500, message: "retry failed"),
        ]

        do {
            _ = try await fixture.store.bind(
                code: pairingCode("2"), serviceURL: serviceURL
            )
            XCTFail("Expected retry failure")
        } catch {}

        XCTAssertEqual(try fixture.store.loadClientIdentity()?.clientID, oldClientID)
        XCTAssertEqual(try fixture.store.loadAll().map(\.computerID), [repeating("1")])
        XCTAssertEqual(fixture.api.reconcileCalls, [])
    }

    func testCorruptStateIsNotTreatedAsAnEmptyInstallation() async throws {
        let memory = MemoryState()
        memory.data = Data("not-json".utf8)
        let api = MockAPI(identities: [try identity(id: repeating("c"))])
        let store = makeStore(memory: memory, api: api)

        do {
            _ = try await store.bind(code: pairingCode("3"), serviceURL: serviceURL)
            XCTFail("Expected state decoding to fail")
        } catch is DecodingError {}

        XCTAssertEqual(api.createCalls, 0)
        XCTAssertEqual(api.bindCalls, [])
        XCTAssertEqual(memory.data, Data("not-json".utf8))
    }

    func testReplacementCommitFailureConvergesTheOrphanIdentityBestEffort() async throws {
        let fixture = try await seededFixture()
        fixture.api.bindErrors = [unauthorized(), nil]
        // The convergence itself failing must not mask the commit error: the
        // orphan identity was never persisted, so nothing can retry for it.
        fixture.api.reconcileError = RollbackFailure.unavailable
        fixture.memory.failNextWrite = true

        do {
            _ = try await fixture.store.bind(
                code: pairingCode("2"), serviceURL: serviceURL
            )
            XCTFail("Expected local commit to fail")
        } catch is StorageFailure {}

        XCTAssertEqual(try fixture.store.loadClientIdentity()?.clientID, oldClientID)
        XCTAssertEqual(try fixture.store.loadAll().map(\.computerID), [repeating("1")])
        XCTAssertEqual(fixture.api.reconcileCalls, [
            .init(computerIDs: [], clientID: replacementClientID),
        ])
    }

    func testUnbindCommitsLocallyEvenWhenTheServiceIsUnreachable() async throws {
        let fixture = try await seededFixture()
        fixture.api.reconcileError = URLError(.cannotConnectToHost)

        try await fixture.store.unbind(computerID: repeating("1"))

        XCTAssertEqual(try fixture.store.loadAll().map(\.computerID), [])
        XCTAssertEqual(fixture.api.reconcileCalls, [
            .init(computerIDs: [], clientID: oldClientID),
        ])
    }

    func testUnbindDeclaresTheRemainingListToTheService() async throws {
        let fixture = try await seededFixture()
        _ = try await fixture.store.bind(code: pairingCode("2"), serviceURL: serviceURL)

        try await fixture.store.unbind(computerID: repeating("1"))

        XCTAssertEqual(try fixture.store.loadAll().map(\.computerID), [repeating("2")])
        XCTAssertEqual(fixture.api.reconcileCalls, [
            .init(computerIDs: [repeating("2")], clientID: oldClientID),
        ])
    }

    func testReconcileRetriesTheLocalListAfterAFailedConvergence() async throws {
        let fixture = try await seededFixture()
        fixture.api.reconcileError = URLError(.cannotConnectToHost)
        try await fixture.store.unbind(computerID: repeating("1"))

        fixture.api.reconcileError = nil
        await fixture.store.reconcile()

        XCTAssertEqual(fixture.api.reconcileCalls, [
            .init(computerIDs: [], clientID: oldClientID),
            .init(computerIDs: [], clientID: oldClientID),
        ])
    }

    func testConcurrentCodesRemainFIFOAcrossIdentityReplacement() async throws {
        let fixture = try await seededFixture()
        fixture.api.bindErrors = [unauthorized(), nil, nil]
        let replacement = try pairingCode("2")
        let next = try pairingCode("3")

        let store = fixture.store
        let serviceURL = serviceURL
        let first = Task { @MainActor in
            try await store.bind(code: replacement, serviceURL: serviceURL)
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await store.bind(code: next, serviceURL: serviceURL)
        }
        _ = try await (first.value, second.value)

        XCTAssertEqual(fixture.api.bindCalls.map(\.clientID), [
            oldClientID, oldClientID, replacementClientID, replacementClientID,
        ])
        XCTAssertEqual(Set(try fixture.store.loadAll().map(\.computerID)), [
            repeating("2"), repeating("3"),
        ])
    }

    func testTerminalManagerTearsDownEveryOldConnectionOnReplacement() async throws {
        let fixture = try await seededFixture()
        let manager = TerminalManager(pairingStore: fixture.store)
        XCTAssertEqual(manager.computers.map(\.id), [repeating("1")])

        fixture.api.bindErrors = [unauthorized(), nil]
        try await manager.addComputer(
            code: pairingCode("2"),
            serviceURL: serviceURL
        )

        XCTAssertEqual(manager.computers.map(\.id), [repeating("2")])
        XCTAssertEqual(manager.terminals, [])
    }

    private struct Fixture {
        let store: PairingStore
        let memory: MemoryState
        let api: MockAPI
    }

    private func seededFixture() async throws -> Fixture {
        let memory = MemoryState()
        let api = MockAPI(identities: [
            try identity(id: oldClientID),
            try identity(id: replacementClientID),
        ])
        let store = makeStore(memory: memory, api: api)
        _ = try await store.bind(code: pairingCode("1"), serviceURL: serviceURL)
        return Fixture(store: store, memory: memory, api: api)
    }

    private func makeStore(memory: MemoryState, api: MockAPI) -> PairingStore {
        PairingStore(
            apiFactory: { _ in api },
            stateReader: { memory.read() },
            stateWriter: { try memory.write($0) }
        )
    }

    private func identity(id: String) throws -> ClientIdentity {
        try ClientIdentity(
            serviceURL: serviceURL,
            clientID: id,
            clientToken: "token-\(id)",
            statusToken: "status-\(id)"
        )
    }

    private func pairingCode(_ marker: Character) throws -> PairingCode {
        try PairingCode(String(repeating: String(marker), count: PairingCode.digitCount))
    }

    private var serviceURL: URL { URL(string: "http://127.0.0.1:8787")! }
    private var oldClientID: String { repeating("a") }
    private var replacementClientID: String { repeating("b") }

    private func unauthorized() -> PedalsServiceAPI.APIError {
        .rejected(status: 401, message: "unauthorized")
    }

    private func repeating(_ character: Character) -> String {
        String(repeating: String(character), count: ComputerBinding.computerIDLength)
    }
}
