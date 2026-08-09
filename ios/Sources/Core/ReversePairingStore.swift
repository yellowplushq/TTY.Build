import Foundation
import PedalsKit
import Security

@MainActor
protocol ReversePairingServiceClient: AnyObject {
    func registerReversePairingToken(
        as client: ClientIdentity
    ) async throws -> ReversePairingToken
    func reversePairingClaims(
        as client: ClientIdentity
    ) async throws -> [ReversePairingClaim]
    func confirmReversePairingClaim(claimID: String, as client: ClientIdentity) async throws
    func rejectReversePairingClaim(claimID: String, as client: ClientIdentity) async throws
    func openReversePairingClaim(
        _ claim: ReversePairingClaim,
        token: ReversePairingToken
    ) throws -> ComputerBinding
}

extension PedalsServiceAPI: ReversePairingServiceClient {}

/// Owns the phone's long-lived enrollment token: the 8-digit code embedded in
/// the desktop install command plus the durable Curve25519 private key that
/// computers seal their secrets to. Stored as its own Keychain value in the
/// same service as the pairing state, in the exact shape PairingStore uses.
///
/// The token deliberately survives app restarts and works while the app is
/// not running; the security gate is the explicit per-computer confirmation
/// the user gives in the app, not the code itself.
@MainActor
final class ReversePairingStore {
    enum StoreError: Error {
        case missingClientIdentity
    }

    private struct PersistentState: Codable {
        let serviceURL: URL
        let token: ReversePairingToken
    }

    typealias APIFactory = @MainActor (URL) -> any ReversePairingServiceClient
    typealias IdentityProvider = @MainActor (URL) async throws -> ClientIdentity
    typealias StateReader = @MainActor () throws -> Data?
    typealias StateWriter = @MainActor (Data) throws -> Void

    private static let service = "air.build.pedals.v2"
    private static let stateAccount = "reverse-pairing-token"

    private let apiFactory: APIFactory
    private let identityProvider: IdentityProvider
    private let stateReader: StateReader
    private let stateWriter: StateWriter
    private var registrationTask: Task<ReversePairingToken, Error>?

    init(
        pairingStore: PairingStore,
        apiFactory: @escaping APIFactory = { PedalsServiceAPI(serviceURL: $0) },
        stateReader: @escaping StateReader = { try ReversePairingStore.readKeychainState() },
        stateWriter: @escaping StateWriter = { try ReversePairingStore.writeKeychainState($0) }
    ) {
        self.apiFactory = apiFactory
        self.identityProvider = { try await pairingStore.ensureClientIdentity(serviceURL: $0) }
        self.stateReader = stateReader
        self.stateWriter = stateWriter
    }

    init(
        apiFactory: @escaping APIFactory,
        identityProvider: @escaping IdentityProvider,
        stateReader: @escaping StateReader,
        stateWriter: @escaping StateWriter
    ) {
        self.apiFactory = apiFactory
        self.identityProvider = identityProvider
        self.stateReader = stateReader
        self.stateWriter = stateWriter
    }

    #if DEBUG
    static func resetKeychainForUITesting() {
        SecItemDelete(query as CFDictionary)
    }
    #endif

    /// Returns the enrollment token for the install command, registering one
    /// (and a client identity, when the installation has neither) on first
    /// use. Concurrent callers share a single registration.
    func ensureToken(serviceURL: URL) async throws -> ReversePairingToken {
        if let state = try? loadState(), state.serviceURL == serviceURL {
            return state.token
        }
        if let running = registrationTask {
            return try await running.value
        }
        let task = Task { [apiFactory, identityProvider, stateWriter] in
            let identity = try await identityProvider(serviceURL)
            let api = apiFactory(serviceURL)
            let token = try await api.registerReversePairingToken(as: identity)
            let state = PersistentState(serviceURL: serviceURL, token: token)
            try stateWriter(try JSONEncoder().encode(state))
            return token
        }
        registrationTask = task
        defer { registrationTask = nil }
        return try await task.value
    }

    /// Completed computer claims waiting for the user's decision. Empty when
    /// the installation has no identity or token yet, or on any failure —
    /// the next launch or foreground retries.
    func pendingClaims(serviceURL: URL) async -> [ReversePairingClaim] {
        guard let state = try? loadState(), state.serviceURL == serviceURL,
              let identity = try? await identityProvider(serviceURL)
        else { return [] }
        let api = apiFactory(serviceURL)
        return (try? await api.reversePairingClaims(as: identity)) ?? []
    }

    /// Decrypts the claim envelope with the durable token key. Pure local
    /// crypto; the caller commits the binding before confirming server-side.
    func openClaim(
        _ claim: ReversePairingClaim,
        serviceURL: URL
    ) throws -> ComputerBinding {
        guard let state = try? loadState(), state.serviceURL == serviceURL else {
            throw StoreError.missingClientIdentity
        }
        let api = apiFactory(serviceURL)
        return try api.openReversePairingClaim(claim, token: state.token)
    }

    func confirmClaim(claimID: String, serviceURL: URL) async throws {
        let identity = try await identityProvider(serviceURL)
        try await apiFactory(serviceURL).confirmReversePairingClaim(
            claimID: claimID, as: identity
        )
    }

    func rejectClaim(claimID: String, serviceURL: URL) async throws {
        let identity = try await identityProvider(serviceURL)
        try await apiFactory(serviceURL).rejectReversePairingClaim(
            claimID: claimID, as: identity
        )
    }

    private func loadState() throws -> PersistentState? {
        guard let data = try stateReader() else { return nil }
        return try JSONDecoder().decode(PersistentState.self, from: data)
    }

    private static func writeKeychainState(_ data: Data) throws {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard update == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(update))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func readKeychainState() throws -> Data? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: stateAccount,
        ]
    }
}
