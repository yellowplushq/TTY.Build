import Foundation
import PedalsKit

/// Synchronous facade used by the daemon's Unix-socket command handler.
/// URLSession remains asynchronous internally; the wait happens off its
/// delegate queues and is bounded by the API request timeout.
public struct ServiceActions: @unchecked Sendable {
    public enum ActionError: Error { case pairingCodesUnavailable }

    public var createComputer: @Sendable (URL) throws -> HostIdentity
    public var deleteComputer: @Sendable (HostIdentity) throws -> Void
    public var createPairingSession: @Sendable (HostIdentity) throws -> HostPairingSession
    public var pairingSessionStatus: @Sendable (
        HostPairingSession, HostIdentity
    ) throws -> HostPairingSessionStatus
    public var completePairingSession: @Sendable (
        HostPairingSession, Data, HostIdentity
    ) throws -> Void
    public var cancelPairingSession: @Sendable (
        HostPairingSession, HostIdentity
    ) throws -> Void
    public var claimReversePairing: @Sendable (
        PairingCode, String, HostIdentity
    ) throws -> Void

    public init(
        createComputer: @escaping @Sendable (URL) throws -> HostIdentity,
        deleteComputer: @escaping @Sendable (HostIdentity) throws -> Void,
        createPairingSession: @escaping @Sendable (HostIdentity) throws -> HostPairingSession = {
            _ in throw ActionError.pairingCodesUnavailable
        },
        pairingSessionStatus: @escaping @Sendable (
            HostPairingSession, HostIdentity
        ) throws -> HostPairingSessionStatus = { _, _ in
            throw ActionError.pairingCodesUnavailable
        },
        completePairingSession: @escaping @Sendable (
            HostPairingSession, Data, HostIdentity
        ) throws -> Void = { _, _, _ in
            throw ActionError.pairingCodesUnavailable
        },
        cancelPairingSession: @escaping @Sendable (
            HostPairingSession, HostIdentity
        ) throws -> Void = { _, _ in },
        claimReversePairing: @escaping @Sendable (
            PairingCode, String, HostIdentity
        ) throws -> Void = { _, _, _ in
            throw ActionError.pairingCodesUnavailable
        }
    ) {
        self.createComputer = createComputer
        self.deleteComputer = deleteComputer
        self.createPairingSession = createPairingSession
        self.pairingSessionStatus = pairingSessionStatus
        self.completePairingSession = completePairingSession
        self.cancelPairingSession = cancelPairingSession
        self.claimReversePairing = claimReversePairing
    }

    public static let live = ServiceActions(
        createComputer: { serviceURL in
            try blocking {
                try await PedalsServiceAPI(serviceURL: serviceURL).createComputer()
            }
        },
        deleteComputer: { identity in
            try blocking {
                try await PedalsServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).deleteComputer(identity: identity)
            }
        },
        createPairingSession: { identity in
            try blocking {
                try await PedalsServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).createPairingSession(identity: identity)
            }
        },
        pairingSessionStatus: { pairing, identity in
            try blocking {
                try await PedalsServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).pairingSessionStatus(pairing, identity: identity)
            }
        },
        completePairingSession: { pairing, clientPublicKey, identity in
            try blocking {
                try await PedalsServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).completePairingSession(
                    pairing,
                    clientPublicKey: clientPublicKey,
                    identity: identity
                )
            }
        },
        cancelPairingSession: { pairing, identity in
            try blocking {
                try await PedalsServiceAPI(
                    serviceURL: identity.computer.serviceURL
                ).cancelPairingSession(pairing, identity: identity)
            }
        },
        claimReversePairing: { code, computerName, identity in
            try blocking {
                try await PedalsServiceAPI(
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
