import Foundation
import TTYBuildKit

/// Synchronous facade used by the daemon's Unix-socket command handler.
/// URLSession remains asynchronous internally; the wait happens off its
/// delegate queues and is bounded by the API request timeout.
public struct ServiceActions: @unchecked Sendable {
    public enum ActionError: Error { case pairingCodesUnavailable }

    public var createComputer: @Sendable (URL) throws -> HostIdentity
    public var deleteComputer: @Sendable (HostIdentity) throws -> Void
    public var createPairingCode: @Sendable (HostIdentity) throws -> HostPairingCode
    public var pairingCodeStatus: @Sendable (
        HostPairingCode, HostIdentity
    ) throws -> HostPairingCodeStatus
    public var completePairingClaim: @Sendable (
        _ claimID: String, _ clientPublicKey: Data, _ privateKey: Data, _ identity: HostIdentity
    ) throws -> Void
    public var cancelPairingCode: @Sendable (
        HostPairingCode, HostIdentity
    ) throws -> Void
    public var claimReversePairing: @Sendable (
        PairingCode, String, HostIdentity
    ) throws -> Void

    public init(
        createComputer: @escaping @Sendable (URL) throws -> HostIdentity,
        deleteComputer: @escaping @Sendable (HostIdentity) throws -> Void,
        createPairingCode: @escaping @Sendable (HostIdentity) throws -> HostPairingCode = {
            _ in throw ActionError.pairingCodesUnavailable
        },
        pairingCodeStatus: @escaping @Sendable (
            HostPairingCode, HostIdentity
        ) throws -> HostPairingCodeStatus = { _, _ in
            throw ActionError.pairingCodesUnavailable
        },
        completePairingClaim: @escaping @Sendable (
            String, Data, Data, HostIdentity
        ) throws -> Void = { _, _, _, _ in
            throw ActionError.pairingCodesUnavailable
        },
        cancelPairingCode: @escaping @Sendable (
            HostPairingCode, HostIdentity
        ) throws -> Void = { _, _ in },
        claimReversePairing: @escaping @Sendable (
            PairingCode, String, HostIdentity
        ) throws -> Void = { _, _, _ in
            throw ActionError.pairingCodesUnavailable
        }
    ) {
        self.createComputer = createComputer
        self.deleteComputer = deleteComputer
        self.createPairingCode = createPairingCode
        self.pairingCodeStatus = pairingCodeStatus
        self.completePairingClaim = completePairingClaim
        self.cancelPairingCode = cancelPairingCode
        self.claimReversePairing = claimReversePairing
    }

    public static let live = ServiceActions(
        createComputer: { serviceURL in
            try blocking {
                try await TTYBuildServiceAPI(serviceURL: serviceURL).createComputer()
            }
        },
        deleteComputer: { identity in
            try blocking {
                try await TTYBuildServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).deleteComputer(identity: identity)
            }
        },
        createPairingCode: { identity in
            try blocking {
                try await TTYBuildServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).createPairingCode(identity: identity)
            }
        },
        pairingCodeStatus: { pairing, identity in
            try blocking {
                try await TTYBuildServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).pairingCodeStatus(pairing, identity: identity)
            }
        },
        completePairingClaim: { claimID, clientPublicKey, privateKey, identity in
            try blocking {
                try await TTYBuildServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).completePairingClaim(
                    claimID: claimID,
                    clientPublicKey: clientPublicKey,
                    privateKey: privateKey,
                    identity: identity
                )
            }
        },
        cancelPairingCode: { pairing, identity in
            try blocking {
                try await TTYBuildServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).cancelPairingCode(pairing, identity: identity)
            }
        },
        claimReversePairing: { code, computerName, identity in
            try blocking {
                try await TTYBuildServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).claimReversePairing(
                    code: code,
                    computerName: computerName,
                    identity: identity
                )
            }
        }
    )
}

private final class ResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func store(_ value: Result<Value, Error>) {
        lock.withLock { self.value = value }
    }

    func load() -> Result<Value, Error>? {
        lock.withLock { value }
    }
}

private func blocking<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<Value>()
    Task.detached {
        do {
            box.store(.success(try await operation()))
        } catch {
            box.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load()!.get()
}
