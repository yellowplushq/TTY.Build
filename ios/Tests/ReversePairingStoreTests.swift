import PedalsKit
import XCTest

@testable import Pedals

@MainActor
final class ReversePairingStoreTests: XCTestCase {
    func testEnsureTokenRegistersOncePersistsAndReturnsTheSameCode() async throws {
        let memory = MemoryState()
        let api = MockAPI(token: try makeToken(code: "01234567"))
        let store = makeStore(memory: memory, api: api)

        let first = try await store.ensureToken(serviceURL: serviceURL)
        XCTAssertEqual(first.code.digits, "01234567")
        XCTAssertEqual(api.registerCount, 1)
        XCTAssertEqual(api.identityRequests, 1)
        XCTAssertNotNil(memory.data)

        // A second call reads the Keychain value; the service is not asked.
        let second = try await store.ensureToken(serviceURL: serviceURL)
        XCTAssertEqual(second, first)
        XCTAssertEqual(api.registerCount, 1)
    }

    func testPendingClaimsAreEmptyBeforeATokenExists() async throws {
        let memory = MemoryState()
        let api = MockAPI(token: try makeToken(code: "01234567"))
        api.claims = [makeClaim(id: repeating("c"))]
        let store = makeStore(memory: memory, api: api)

        let before = await store.pendingClaims(serviceURL: serviceURL)
        XCTAssertEqual(before, [])

        _ = try await store.ensureToken(serviceURL: serviceURL)
        let after = await store.pendingClaims(serviceURL: serviceURL)
        XCTAssertEqual(after.map(\.claimID), [repeating("c")])
    }

    func testConfirmAndRejectForwardTheClaimID() async throws {
        let memory = MemoryState()
        let api = MockAPI(token: try makeToken(code: "01234567"))
        let store = makeStore(memory: memory, api: api)
        _ = try await store.ensureToken(serviceURL: serviceURL)

        try await store.confirmClaim(claimID: repeating("d"), serviceURL: serviceURL)
        try await store.rejectClaim(claimID: repeating("e"), serviceURL: serviceURL)
        XCTAssertEqual(api.confirmed, [repeating("d")])
        XCTAssertEqual(api.rejected, [repeating("e")])
    }

    func testOpenClaimRequiresAStoredToken() throws {
        let memory = MemoryState()
        let api = MockAPI(token: try makeToken(code: "01234567"))
        let store = makeStore(memory: memory, api: api)

        XCTAssertThrowsError(
            try store.openClaim(makeClaim(id: repeating("f")), serviceURL: serviceURL)
        )
    }

    // MARK: - PairingStore reverse-pairing commits

    func testCommitReversePairedBindingRequiresIdentityThenPersistsBinding() async throws {
        let memory = MemoryState()
        let pairingAPI = MockPairingAPI()
        let pairingStore = PairingStore(
            apiFactory: { _ in pairingAPI },
            stateReader: { memory.data },
            stateWriter: { memory.data = $0 }
        )
        let binding = try ComputerBinding(
            serviceURL: serviceURL,
            computerID: repeating("1"),
            secret: Data(repeating: 9, count: 32)
        )

        // No identity yet: the commit must fail rather than invent one.
        do {
            _ = try await pairingStore.commitReversePairedBinding(binding)
            XCTFail("expected missingClientIdentity")
        } catch {}

        let identity = try await pairingStore.ensureClientIdentity(serviceURL: serviceURL)
        XCTAssertEqual(pairingAPI.createdClients, 1)

        // ensureClientIdentity is idempotent once persisted.
        let again = try await pairingStore.ensureClientIdentity(serviceURL: serviceURL)
        XCTAssertEqual(again, identity)
        XCTAssertEqual(pairingAPI.createdClients, 1)

        let committed = try await pairingStore.commitReversePairedBinding(binding)
        XCTAssertEqual(committed, identity)
        XCTAssertEqual(try pairingStore.loadAll().map(\.computerID), [repeating("1")])
    }

    // MARK: - Fixtures

    private final class MemoryState {
        var data: Data?
    }

    private final class MockAPI: ReversePairingServiceClient {
        var registerCount = 0
        var identityRequests = 0
        var claims: [ReversePairingClaim] = []
        var confirmed: [String] = []
        var rejected: [String] = []
        private let token: ReversePairingToken

        init(token: ReversePairingToken) {
            self.token = token
        }

        func registerReversePairingToken(
            as client: ClientIdentity
        ) async throws -> ReversePairingToken {
            registerCount += 1
            return token
        }

        func reversePairingClaims(
            as client: ClientIdentity
        ) async throws -> [ReversePairingClaim] {
            claims
        }

        func confirmReversePairingClaim(claimID: String, as client: ClientIdentity) async throws {
            confirmed.append(claimID)
        }

        func rejectReversePairingClaim(claimID: String, as client: ClientIdentity) async throws {
            rejected.append(claimID)
        }

        func openReversePairingClaim(
            _ claim: ReversePairingClaim,
            token: ReversePairingToken
        ) throws -> ComputerBinding {
            try ComputerBinding(
                serviceURL: URL(string: "http://127.0.0.1:8787")!,
                computerID: claim.computerID,
                secret: Data(repeating: 1, count: 32)
            )
        }
    }

    private final class MockPairingAPI: PairingServiceClient {
        var createdClients = 0

        func createClient() async throws -> ClientIdentity {
            createdClients += 1
            return try ClientIdentity(
                serviceURL: URL(string: "http://127.0.0.1:8787")!,
                clientID: String(repeating: "9", count: 32),
                clientToken: "token-mock-pairing-client-000000",
                statusToken: "status-mock-pairing-client-00000"
            )
        }

        func pair(code: PairingCode, as client: ClientIdentity) async throws -> ComputerBinding {
            throw PedalsServiceAPI.APIError.invalidResponse
        }

        func reconcileBindings(
            computerIDs: [String],
            as client: ClientIdentity
        ) async throws -> [String] {
            computerIDs
        }
    }

    private func makeStore(memory: MemoryState, api: MockAPI) -> ReversePairingStore {
        ReversePairingStore(
            apiFactory: { _ in api },
            identityProvider: { [weak api] serviceURL in
                api?.identityRequests += 1
                return try ClientIdentity(
                    serviceURL: serviceURL,
                    clientID: String(repeating: "8", count: 32),
                    clientToken: "token-reverse-pairing-client-000",
                    statusToken: "status-reverse-pairing-client-00"
                )
            },
            stateReader: { memory.data },
            stateWriter: { memory.data = $0 }
        )
    }

    private func makeToken(code: String) throws -> ReversePairingToken {
        ReversePairingToken(
            code: try PairingCode(code),
            privateKey: Data(repeating: 3, count: 32)
        )
    }

    private func makeClaim(id: String) -> ReversePairingClaim {
        ReversePairingClaim(
            claimID: id,
            computerID: repeating("a"),
            computerName: "Studio",
            hostPublicKey: Data(repeating: 2, count: 32),
            encryptedSecret: Data(repeating: 4, count: 80),
            createdAt: 0
        )
    }

    private var serviceURL: URL { URL(string: "http://127.0.0.1:8787")! }

    private func repeating(_ character: Character) -> String {
        String(repeating: String(character), count: 32)
    }
}
