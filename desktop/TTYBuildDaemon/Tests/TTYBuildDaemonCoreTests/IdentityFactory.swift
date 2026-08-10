import Foundation
import TTYBuildKit

@testable import TTYBuildDaemonCore

/// Shared in-memory ServiceActions factory for full-daemon tests
/// (DaemonControlTests, DaemonAttachTests, DaemonAgentControlTests).
final class IdentityFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var computerCounter = 0
    private var inviteCounter = 0
    private var recordedEvents: [String] = []
    private var shouldFailDelete = false
    private var shouldFailNextCreate = false

    private enum FactoryError: Error {
        case requestedCreateFailure
        case requestedDeleteFailure
    }

    var events: [String] { lock.withLock { recordedEvents } }

    var failDelete: Bool {
        get { lock.withLock { shouldFailDelete } }
        set { lock.withLock { shouldFailDelete = newValue } }
    }

    var failNextCreate: Bool {
        get { lock.withLock { shouldFailNextCreate } }
        set { lock.withLock { shouldFailNextCreate = newValue } }
    }

    func clearEvents() {
        lock.withLock { recordedEvents.removeAll() }
    }

    var actions: ServiceActions {
        ServiceActions(
            createComputer: { [self] serviceURL in
                try lock.withLock {
                    recordedEvents.append("create")
                    if shouldFailNextCreate {
                        shouldFailNextCreate = false
                        throw FactoryError.requestedCreateFailure
                    }
                    computerCounter += 1
                    let hex = String(format: "%032x", computerCounter)
                    let binding = try ComputerBinding(
                        serviceURL: serviceURL,
                        computerID: hex,
                        secret: Data(repeating: UInt8(computerCounter), count: 32)
                    )
                    return HostIdentity(computer: binding, hostToken: "host-\(hex)")
                }
            },
            deleteComputer: { [self] identity in
                try lock.withLock {
                    recordedEvents.append("delete:\(identity.computer.computerID)")
                    if shouldFailDelete {
                        throw FactoryError.requestedDeleteFailure
                    }
                }
            },
            createPairingCode: { [self] identity in
                try lock.withLock {
                    recordedEvents.append("pairing:\(identity.computer.computerID)")
                    inviteCounter += 1
                    return HostPairingCode(
                        codeID: String(format: "%032x", inviteCounter),
                        code: try PairingCode(String(format: "%08d", inviteCounter)),
                        expiresAt: Int64(Date().timeIntervalSince1970) + 900,
                        privateKey: Data(repeating: UInt8(inviteCounter), count: 32)
                    )
                }
            },
            pairingCodeStatus: { _, _ in .waiting },
            completePairingClaim: { _, _, _, _ in },
            cancelPairingCode: { _, _ in },
            claimReversePairing: { [self] code, computerName, identity in
                lock.withLock {
                    recordedEvents.append(
                        "claim:\(code.digits):\(computerName):\(identity.computer.computerID)"
                    )
                }
            }
        )
    }
}
