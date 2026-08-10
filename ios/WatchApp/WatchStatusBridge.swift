import Foundation
import WatchConnectivity
import WidgetKit

@MainActor
final class WatchStatusBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchStatusBridge()

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        applyDecoded(applicationContext: session.receivedApplicationContext)
    }

    /// `applicationContext` is the durable fallback, but it can represent an
    /// intermediate phone state. While both apps are reachable, ask for the
    /// phone's current value so a Watch reinstall, transient provisioning
    /// failure, or revoked credential cannot leave the Watch wedged.
    func requestCurrentContext() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        // WatchConnectivity invokes the reply on its own utility queue. A
        // closure formed in this MainActor-isolated method inherits that
        // isolation, and the Swift runtime traps at its entry when it runs
        // off-main (EXC_BREAKPOINT in _dispatch_assert_queue_fail — this
        // crashed 1.0.1 (8) at launch whenever the phone was reachable).
        // @Sendable severs the isolation inheritance; the body only builds
        // Sendable values and hops to MainActor for the actual apply.
        session.sendMessage(
            [WatchTerminalContext.requestMessageKey: true],
            replyHandler: { @Sendable [weak self] applicationContext in
                let statusContext = WatchStatusContext(
                    applicationContext: applicationContext
                )
                let terminalUpdate = WatchTerminalContextUpdate(
                    applicationContext: applicationContext
                )
                Task { @MainActor [weak self] in
                    self?.apply(
                        statusContext: statusContext,
                        terminalUpdate: terminalUpdate
                    )
                }
            },
            errorHandler: nil
        )
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        let applicationContext = session.receivedApplicationContext
        let statusContext = WatchStatusContext(applicationContext: applicationContext)
        let terminalUpdate = WatchTerminalContextUpdate(
            applicationContext: applicationContext
        )
        Task { @MainActor [weak self] in
            self?.apply(statusContext: statusContext, terminalUpdate: terminalUpdate)
            self?.requestCurrentContext()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let statusContext = WatchStatusContext(applicationContext: applicationContext)
        let terminalUpdate = WatchTerminalContextUpdate(
            applicationContext: applicationContext
        )
        Task { @MainActor [weak self] in
            self?.apply(statusContext: statusContext, terminalUpdate: terminalUpdate)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor [weak self] in
            self?.requestCurrentContext()
        }
    }

    private func applyDecoded(applicationContext: [String: Any]) {
        apply(
            statusContext: WatchStatusContext(applicationContext: applicationContext),
            terminalUpdate: WatchTerminalContextUpdate(
                applicationContext: applicationContext
            )
        )
    }

    private func apply(
        statusContext context: WatchStatusContext?,
        terminalUpdate: WatchTerminalContextUpdate?
    ) {
        if let terminalUpdate {
            WatchTerminalStore.shared.install(terminalUpdate)
        }
        guard let context else { return }

        // Render the companion's freshest snapshot immediately. Credential
        // installation and endpoint delivery use short durable transactions
        // off MainActor and must never stall the Watch UI on network I/O.
        StatusSharedStore.saveSnapshot(context.snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: TTYBuildStatusConstants.watchWidgetKind)
        Task { [context] in
            let changed = await StatusSharedStore.saveCredential(context.credential)
            if changed {
                // A client replacement resets the monotonic snapshot store.
                // Re-apply the new client's companion snapshot before doing
                // any network work so the Watch never waits on APNs setup.
                StatusSharedStore.saveSnapshot(context.snapshot)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: TTYBuildStatusConstants.watchWidgetKind
                )
            }
            await PushEndpointRegistrar.flushPending()
            _ = try? await TTYBuildStatusRuntime.refreshState()
        }
    }
}
