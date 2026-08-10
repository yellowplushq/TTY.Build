import Foundation
import TTYBuildKit
import Security

@MainActor
protocol WatchTerminalServiceClient: AnyObject {
    func createClient() async throws -> ClientIdentity
    func synchronizeBindings(
        from source: ClientIdentity,
        to delegate: ClientIdentity
    ) async throws -> Int
}

extension TTYBuildServiceAPI: WatchTerminalServiceClient {}

/// Owns the Watch's independent relay principal. The iPhone authorizes the
/// service to copy only its current binding edges to this principal, then sends
/// the corresponding E2EE secrets directly to the paired Watch.
@MainActor
final class WatchTerminalProvisioner {
    typealias APIFactory = @MainActor (URL) -> any WatchTerminalServiceClient
    typealias StateReader = @MainActor () throws -> Data?
    typealias StateWriter = @MainActor (Data) throws -> Void

    private static let service = "air.build.pedals.v2"
    private static let identityAccount = "watch-terminal-client"

    private let apiFactory: APIFactory
    private let stateReader: StateReader
    private let stateWriter: StateWriter

    convenience init() {
        self.init(
            apiFactory: { TTYBuildServiceAPI(serviceURL: $0) },
            stateReader: { try Self.readKeychainState() },
            stateWriter: { try Self.writeKeychainState($0) }
        )
    }

    init(
        apiFactory: @escaping APIFactory,
        stateReader: @escaping StateReader,
        stateWriter: @escaping StateWriter
    ) {
        self.apiFactory = apiFactory
        self.stateReader = stateReader
        self.stateWriter = stateWriter
    }

    func context(
        source: ClientIdentity,
        bindings: [ComputerBinding]
    ) async throws -> WatchTerminalContext {
        let api = apiFactory(source.serviceURL)
        var delegate: ClientIdentity?
        do {
            delegate = try loadIdentity()
        } catch is DecodingError {
            // This credential is replaceable and contains no computer secret;
            // a corrupt value can be safely superseded by a fresh principal.
            delegate = nil
        }
        if delegate?.serviceURL != source.serviceURL || delegate?.clientID == source.clientID {
            delegate = nil
        }
        if delegate == nil {
            delegate = try await createAndPersistIdentity(using: api)
        }
        guard var resolvedDelegate = delegate else {
            throw TTYBuildServiceAPI.APIError.invalidResponse
        }

        do {
            _ = try await api.synchronizeBindings(from: source, to: resolvedDelegate)
        } catch {
            guard Self.isInvalidDelegate(error) else { throw error }
            resolvedDelegate = try await createAndPersistIdentity(using: api)
            _ = try await api.synchronizeBindings(from: source, to: resolvedDelegate)
        }

        return WatchTerminalContext(
            identity: resolvedDelegate,
            bindings: bindings,
            revision: WatchTerminalContext.currentRevision
        )
    }

    #if DEBUG
    static func resetKeychainForUITesting() {
        SecItemDelete(query as CFDictionary)
    }
    #endif

    private func createAndPersistIdentity(
        using api: any WatchTerminalServiceClient
    ) async throws -> ClientIdentity {
        let identity = try await api.createClient()
        try stateWriter(JSONEncoder().encode(identity))
        return identity
    }

    private func loadIdentity() throws -> ClientIdentity? {
        guard let data = try stateReader() else { return nil }
        return try JSONDecoder().decode(ClientIdentity.self, from: data)
    }

    private static func isInvalidDelegate(_ error: Error) -> Bool {
        guard case TTYBuildServiceAPI.APIError.rejected(let status, _) = error else {
            return false
        }
        return status == 403
    }

    private static func writeKeychainState(_ data: Data) throws {
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

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
            kSecAttrAccount as String: identityAccount,
        ]
    }
}
