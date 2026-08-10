import AppKit
import TTYBuildDaemonCore
import TTYBuildKit
import SwiftUI

private final class NotificationObserverToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(center: NotificationCenter, token: any NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}

enum RelayState: Equatable {
    case starting
    case connecting
    case connected
    case unavailable

    var label: String {
        switch self {
        case .starting: "Starting tty.build…"
        case .connecting: "Connecting to service…"
        case .connected: "Connected"
        case .unavailable: "Service unavailable"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let pairedDeviceKey = "hasPairedDesktopClientV1"
    private static let legacyOnboardingKey = "completedDesktopOnboardingV2"
    /// Overridable like the iOS app's TTYBUILD_SERVICE_URL so local relay
    /// end-to-end runs never register throwaway identities in production.
    private static let productionService =
        ProcessInfo.processInfo.environment["TTYBUILD_SERVICE_URL"]
        ?? "https://tty.build"
    private static let pairingDefocusGracePeriod = Duration.seconds(30)

    @Published private(set) var serviceRunning = false
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var clientConnected = false
    @Published private(set) var relayState: RelayState = .starting
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingExpiresAt: Date?
    @Published private(set) var isLoadingPairingCode = false
    @Published private(set) var isStartingService = false
    @Published private(set) var hasPairedDevice: Bool
    @Published var lastError: String?

    private var service: TTYBuildService?
    /// Injected by the app delegate; backs client-triggered update requests
    /// (PROTOCOL.md §5). Setting it re-wires the daemon's update handlers.
    var updater: UpdaterModel? {
        didSet { wireUpdateHandlers() }
    }
    private var startupTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var reversePairingTask: Task<Void, Never>?
    private var enrollmentStampTask: Task<Void, Never>?
    private var pairingRevocationTask: Task<Void, Never>?
    private var pairingRefreshTask: Task<Void, Never>?
    private var pairingPresentationIsFocused = false
    private var terminationObserver: NotificationObserverToken?
    private var sleepObserver: NotificationObserverToken?
    private var wakeObserver: NotificationObserverToken?

    init() {
        let defaults = UserDefaults.standard
        let completedLegacyPairing = defaults.bool(forKey: Self.legacyOnboardingKey)
        hasPairedDevice = defaults.bool(forKey: Self.pairedDeviceKey) || completedLegacyPairing
        if completedLegacyPairing {
            defaults.set(true, forKey: Self.pairedDeviceKey)
            defaults.removeObject(forKey: Self.legacyOnboardingKey)
        }
        defaults.removeObject(forKey: "daemonBinaryPath")

        let terminationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pairingTask?.cancel()
                self?.pairingRevocationTask?.cancel()
                self?.pairingRefreshTask?.cancel()
                self?.reversePairingTask?.cancel()
                self?.enrollmentStampTask?.cancel()
                self?.monitoringTask?.cancel()
                self?.startupTask?.cancel()
                self?.service?.shutdown()
            }
        }
        terminationObserver = NotificationObserverToken(
            center: .default, token: terminationToken
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.service?.suspend() }
        }
        sleepObserver = NotificationObserverToken(center: workspaceCenter, token: sleepToken)
        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.service?.resume() }
        }
        wakeObserver = NotificationObserverToken(center: workspaceCenter, token: wakeToken)

        startService()
    }

    // MARK: Service lifecycle

    func retryService() {
        startService()
    }

    private func startService() {
        guard service == nil, startupTask == nil else { return }
        isStartingService = true
        relayState = .starting
        lastError = nil
        let productionService = Self.productionService

        startupTask = Task { [weak self] in
            do {
                let service = try await Task.detached(priority: .userInitiated) {
                    let home = TTYBuildHome()
                    try home.save(config: .init(service: productionService))
                    let service = try TTYBuildService(home: home)
                    try service.start()
                    return service
                }.value

                guard let self, !Task.isCancelled else {
                    service.shutdown()
                    return
                }
                self.service = service
                wireUpdateHandlers()
                serviceRunning = true
                isStartingService = false
                startupTask = nil
                await refresh()
                startMonitoring()
                startEnrollmentStampMonitor()
            } catch {
                guard let self, !Task.isCancelled else { return }
                monitoringTask?.cancel()
                monitoringTask = nil
                serviceRunning = false
                isStartingService = false
                relayState = .unavailable
                lastError = "Could not start tty.build: \(error.localizedDescription)"
                startupTask = nil
            }
        }
    }

    // MARK: Polling

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                await refresh()
            }
        }
    }

    func refresh() async {
        guard let service else {
            sessions = []
            clientConnected = false
            return
        }

        let snapshot = await Task.detached(priority: .utility) {
            service.snapshot()
        }.value
        sessions = snapshot.sessions
        clientConnected = snapshot.clientConnected
        serviceRunning = true
        relayState = switch snapshot.relayState {
        case .stopped: .unavailable
        case .connecting: .connecting
        case .connected: .connected
        }

        if clientConnected, !hasPairedDevice {
            UserDefaults.standard.set(true, forKey: Self.pairedDeviceKey)
            hasPairedDevice = true
            finishPairingPresentation()
        }
    }

    // MARK: Session actions

    /// Routes client-triggered update requests to the injected Sparkle
    /// updater. Re-applied whenever the service or the updater changes.
    private func wireUpdateHandlers() {
        guard let service else { return }
        service.setUpdateHandlers(
            status: { [weak self] in
                guard let self, let updater = await self.updater else {
                    return RemoteManagement.UpdateStatus(
                        updateAvailable: false, detail: "the updater is unavailable"
                    )
                }
                return await updater.checkUpdateInformation()
            },
            install: { [weak self] in
                guard let self, let updater = await self.updater else {
                    return RemoteManagement.UpdateStatus(
                        updateAvailable: false, detail: "the updater is unavailable"
                    )
                }
                return await updater.installUpdate()
            }
        )
    }

    func closeSession(_ id: Int) {
        guard let service else { return }
        lastError = nil
        Task {
            let closed = await Task.detached(priority: .userInitiated) {
                service.closeSession(id: id)
            }.value
            await refresh()
            lastError = closed ? nil : "Session \(id) is no longer available"
        }
    }

    // MARK: Reverse pairing (enrollment stamp)

    /// The install script and paired downloads leave the enrollment code as
    /// an extended attribute on the app bundle. Consume it whenever the
    /// service is up: claim fire-and-forget, then remove the stamp on any
    /// terminal outcome. A network failure keeps the stamp for the periodic
    /// retry below and for the next launch. The phone is the only surface
    /// that shows pairing state, so failures are logged rather than
    /// displayed.
    func consumeEnrollmentStamp(bundleURL: URL = Bundle.main.bundleURL) {
        guard reversePairingTask == nil,
              let code = EnrollmentCodeStamp.read(bundleURL: bundleURL),
              let service
        else { return }
        reversePairingTask = Task { [weak self] in
            defer { self?.reversePairingTask = nil }
            let computerName = Host.current().localizedName ?? "Mac"
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.claimReversePairing(
                        code: code,
                        computerName: computerName
                    )
                }.value
                NSLog("tty.build submitted an enrollment claim; confirm on the iPhone")
            } catch {
                // Only a definitive service rejection (unknown or replaced
                // code) is terminal. Rate limits, service errors, and
                // transport failures keep the stamp for the periodic retry.
                guard Self.isTerminalClaimRejection(error) else {
                    NSLog(
                        "tty.build enrollment claim failed, will retry: %@",
                        error.localizedDescription
                    )
                    return
                }
                NSLog("tty.build enrollment claim was rejected: %@", "\(error)")
            }
            EnrollmentCodeStamp.clear(bundleURL: bundleURL)
        }
    }

    private static func isTerminalClaimRejection(_ error: Error) -> Bool {
        guard case TTYBuildServiceAPI.APIError.rejected(let status, _) = error else {
            return false
        }
        return (400 ..< 500).contains(status) && status != 429
    }

    private func startEnrollmentStampMonitor() {
        enrollmentStampTask?.cancel()
        consumeEnrollmentStamp()
        // One getxattr syscall every 30 s: catches an install that ran while
        // this instance kept running, and retries after transient failures.
        enrollmentStampTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.consumeEnrollmentStamp()
            }
        }
    }

    // MARK: Pairing

    func presentPairingCode() {
        pairingPresentationIsFocused = true
        cancelPairingRevocation()
        guard !isLoadingPairingCode else { return }
        guard let pairingCode, let pairingExpiresAt, pairingExpiresAt > Date() else {
            fetchPairingCode()
            return
        }
        schedulePairingRefresh(code: pairingCode, expiresAt: pairingExpiresAt)
    }

    func fetchPairingCode() {
        guard let service else { return }
        pairingPresentationIsFocused = true
        cancelPairingRevocation()
        cancelPairingRefresh()
        pairingTask?.cancel()
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = true

        pairingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isLoadingPairingCode = false
                pairingTask = nil
            }
            do {
                let invitation = try await Task.detached(priority: .userInitiated) {
                    try service.createPairingInvitation()
                }.value
                guard !Task.isCancelled else { return }
                pairingCode = invitation.code.digits
                pairingExpiresAt = invitation.expiresAt
                lastError = nil
                if pairingPresentationIsFocused {
                    schedulePairingRefresh(
                        code: invitation.code.digits,
                        expiresAt: invitation.expiresAt
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                pairingCode = nil
                pairingExpiresAt = nil
                lastError = "Could not create a connection code: \(error.localizedDescription)"
            }
        }
    }

    func clearPairingCode() {
        pairingPresentationIsFocused = false
        cancelPairingRevocation()
        cancelPairingRefresh()
        pairingTask?.cancel()
        pairingTask = nil
        let shouldRevoke = pairingCode != nil || isLoadingPairingCode
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = false
        guard shouldRevoke, let service else { return }
        Task.detached(priority: .utility) {
            service.cancelPairingInvitation()
        }
    }

    /// A menu-bar popover disappears as soon as the user clicks an iPhone
    /// Simulator. Keep its code alive briefly so that interaction is treated
    /// differently from an explicit Hide Code action.
    func schedulePairingRevocationAfterDefocus() {
        pairingPresentationIsFocused = false
        cancelPairingRefresh()
        cancelPairingRevocation()
        guard pairingCode != nil || isLoadingPairingCode else { return }

        pairingRevocationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.pairingDefocusGracePeriod)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            pairingRevocationTask = nil
            clearPairingCode()
        }
    }

    private func cancelPairingRevocation() {
        pairingRevocationTask?.cancel()
        pairingRevocationTask = nil
    }

    private func schedulePairingRefresh(code: String, expiresAt: Date) {
        cancelPairingRefresh()
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        pairingRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  pairingPresentationIsFocused,
                  pairingCode == code,
                  pairingExpiresAt == expiresAt
            else { return }
            pairingRefreshTask = nil
            fetchPairingCode()
        }
    }

    private func cancelPairingRefresh() {
        pairingRefreshTask?.cancel()
        pairingRefreshTask = nil
    }

    private func finishPairingPresentation() {
        pairingPresentationIsFocused = false
        cancelPairingRevocation()
        cancelPairingRefresh()
        pairingTask?.cancel()
        pairingTask = nil
        pairingCode = nil
        pairingExpiresAt = nil
        isLoadingPairingCode = false
    }
}
