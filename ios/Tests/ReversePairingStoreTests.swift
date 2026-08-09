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

    func testEnsureTokenRefreshesAnExpiredCodeReusingTheDurableKey() async throws {
        let memory = MemoryState()
        let api = MockAPI(token: try makeToken(code: "01234567", expiresIn: -10))
        let store = makeStore(memory: memory, api: api)

        let expired = try await store.ensureToken(serviceURL: serviceURL)
        XCTAssertEqual(api.registerCount, 1)
        XCTAssertFalse(expired.isUsable())

        // The stored code is stale: the next call re-registers, handing the
        // service the SAME durable private key so pending envelopes sealed
        // under the old code stay confirmable.
        api.token = try makeToken(code: "76543210", expiresIn: 3_600)
        let refreshed = try await store.ensureToken(serviceURL: serviceURL)
        XCTAssertEqual(refreshed.code.digits, "76543210")
        XCTAssertEqual(api.registerCount, 2)
        XCTAssertEqual(api.reusedKeys.last ?? nil, expired.privateKey)

        // The refreshed token is fresh — no third registration.
        _ = try await store.ensureToken(serviceURL: serviceURL)
        XCTAssertEqual(api.registerCount, 2)
    }

    func testEnsureTokenRecreatesASweptClientIdentityOnce() async throws {
        let memory = MemoryState()
        let api = MockAPI(token: try makeToken(code: "01234567"))
        api.registerErrors = [PedalsServiceAPI.APIError.rejected(status: 401, message: "unauthorized")]
        let store = makeStore(memory: memory, api: api)

        let token = try await store.ensureToken(serviceURL: serviceURL)
        XCTAssertEqual(token.code.digits, "01234567")
        XCTAssertEqual(api.registerCount, 2)
        XCTAssertEqual(api.recreations, 1)
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
        var recreations = 0
        var claims: [ReversePairingClaim] = []
        var confirmed: [String] = []
        var rejected: [String] = []
        var reusedKeys: [Data?] = []
        var registerErrors: [Error] = []
        var token: ReversePairingToken

        init(token: ReversePairingToken) {
            self.token = token
        }

        func registerReversePairingToken(
            as client: ClientIdentity,
            reusingPrivateKey: Data?
        ) async throws -> ReversePairingToken {
            registerCount += 1
            reusedKeys.append(reusingPrivateKey)
            if !registerErrors.isEmpty {
                throw registerErrors.removeFirst()
            }
            if let reusingPrivateKey {
                return ReversePairingToken(
                    code: token.code,
                    privateKey: reusingPrivateKey,
                    expiresAt: token.expiresAt
                )
            }
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
                return try Self.identity(serviceURL: serviceURL, marker: "8")
            },
            identityRecreator: { [weak api] serviceURL in
                api?.recreations += 1
                return try Self.identity(serviceURL: serviceURL, marker: "7")
            },
            stateReader: { memory.data },
            stateWriter: { memory.data = $0 }
        )
    }

    private static func identity(serviceURL: URL, marker: Character) throws -> ClientIdentity {
        try ClientIdentity(
            serviceURL: serviceURL,
            clientID: String(repeating: String(marker), count: 32),
            clientToken: "token-reverse-pairing-client-00\(marker)",
            statusToken: "status-reverse-pairing-client-0\(marker)"
        )
    }

    private func makeToken(
        code: String,
        expiresIn: TimeInterval = 3_600
    ) throws -> ReversePairingToken {
        ReversePairingToken(
            code: try PairingCode(code),
            privateKey: Data(repeating: 3, count: 32),
            expiresAt: Int64(Date().timeIntervalSince1970 + expiresIn)
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
