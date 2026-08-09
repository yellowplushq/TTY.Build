import Combine
import PedalsDaemonCore
import Sparkle

/// `SPUUpdater` takes its delegate at init, so the probing-check callbacks
/// land here and are forwarded into `UpdaterModel`'s MainActor state.
private final class UpdaterProbeDelegate: NSObject, SPUUpdaterDelegate {
    var onFound: @MainActor (SUAppcastItem) -> Void = { _ in }
    var onCycleFinished: @MainActor ((any Error)?) -> Void = { _ in }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let onFound = onFound
        Task { await onFound(item) }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor check: SPUUpdateCheck,
        error: (any Error)?
    ) {
        let onCycleFinished = onCycleFinished
        Task { await onCycleFinished(error) }
    }
}

/// The standard Sparkle UI driver plus a silent mode for client-triggered
/// installs (PROTOCOL.md §5): while a remote install is in flight it answers
/// every prompt itself — install, then relaunch — so the update runs to
/// completion without anyone clicking on the Mac.
private final class RemoteInstallUserDriver: SPUStandardUserDriver {
    private(set) var silentInstall = false

    func beginSilentInstall() { silentInstall = true }
    func endSilentInstall() { silentInstall = false }

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard !silentInstall else { return }
        super.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard silentInstall else {
            return super.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
        reply(appcastItem.isInformationOnlyUpdate ? .dismiss : .install)
    }

    override func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard !silentInstall else { return }
        super.showUpdateReleaseNotes(with: downloadData)
    }

    override func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        guard !silentInstall else { return }
        super.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    override func showUpdateNotFoundWithError(
        _ error: any Error, acknowledgement: @escaping () -> Void
    ) {
        guard !silentInstall else { return acknowledgement() }
        super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    override func showUpdaterError(
        _ error: any Error, acknowledgement: @escaping () -> Void
    ) {
        guard !silentInstall else { return acknowledgement() }
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard !silentInstall else { return }
        super.showDownloadInitiated(cancellation: cancellation)
    }

    override func showDownloadDidReceiveExpectedContentLength(
        _ expectedContentLength: UInt64
    ) {
        guard !silentInstall else { return }
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard !silentInstall else { return }
        super.showDownloadDidReceiveData(ofLength: length)
    }

    override func showDownloadDidStartExtractingUpdate() {
        guard !silentInstall else { return }
        super.showDownloadDidStartExtractingUpdate()
    }

    override func showExtractionReceivedProgress(_ progress: Double) {
        guard !silentInstall else { return }
        super.showExtractionReceivedProgress(progress)
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !silentInstall else { return reply(.install) }
        super.showReady(toInstallAndRelaunch: reply)
    }

    override func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard !silentInstall else { return }
        super.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    override func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool, acknowledgement: @escaping () -> Void
    ) {
        guard !silentInstall else { return acknowledgement() }
        super.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    override func showUpdateInFocus() {
        guard !silentInstall else { return }
        super.showUpdateInFocus()
    }

    override func dismissUpdateInstallation() {
        guard !silentInstall else { return }
        super.dismissUpdateInstallation()
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    let updater: SPUUpdater

    @Published private(set) var canCheckForUpdates = false

    private let userDriver: RemoteInstallUserDriver
    private let probeDelegate: UpdaterProbeDelegate

    /// Result of the in-flight `checkForUpdateInformation` probe, delivered
    /// to the pending continuation by `didFinishUpdateCycleForUpdateCheck`.
    private var probeItem: SUAppcastItem?
    private var probeContinuation: CheckedContinuation<
        (item: SUAppcastItem?, error: (any Error)?), Never
    >?

    init() {
        let probeDelegate = UpdaterProbeDelegate()
        let userDriver = RemoteInstallUserDriver(hostBundle: .main, delegate: nil)
        self.probeDelegate = probeDelegate
        self.userDriver = userDriver
        updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main,
            userDriver: userDriver, delegate: probeDelegate
        )

        probeDelegate.onFound = { [weak self] item in
            // Only record finds for our own probes: UI-driven checks also
            // fire this and must not leak into a later probe's result.
            guard let self, probeContinuation != nil else { return }
            probeItem = item
        }
        probeDelegate.onCycleFinished = { [weak self] error in
            guard let self else { return }
            if let continuation = probeContinuation {
                probeContinuation = nil
                let item = probeItem
                probeItem = nil
                continuation.resume(returning: (item, error))
            } else {
                // A silent install cycle only ends here when it failed or
                // was dismissed (success relaunches the app) — restore the
                // interactive driver for local checks.
                userDriver.endSilentInstall()
            }
        }

        do {
            try updater.start()
        } catch {
            NSLog("Pedals: Sparkle updater failed to start: %@", String(describing: error))
        }

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// The running build's marketing version.
    var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // MARK: - Client-triggered updates (PROTOCOL.md §5)

    /// Probing, UI-free check used to answer a client's `update-status`
    /// request. Respects Sparkle's skipped versions and OS requirements.
    func checkUpdateInformation() async -> RemoteManagement.UpdateStatus {
        let current = currentVersion
        guard !updater.sessionInProgress, probeContinuation == nil else {
            return RemoteManagement.UpdateStatus(
                current: current, updateAvailable: false,
                detail: "an update session is already in progress"
            )
        }
        let probe: (item: SUAppcastItem?, error: (any Error)?) = await withCheckedContinuation { continuation in
            probeContinuation = continuation
            updater.checkForUpdateInformation()
        }
        if let error = probe.error {
            // Sparkle ends a no-update probe with SUNoUpdateError; that's
            // the up-to-date case, not a failure.
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain,
                nsError.code == Int(SUError.noUpdateError.rawValue) {
                return RemoteManagement.UpdateStatus(
                    current: current, updateAvailable: false
                )
            }
            return RemoteManagement.UpdateStatus(
                current: current, updateAvailable: false,
                detail: "update check failed: \(error.localizedDescription)"
            )
        }
        if let item = probe.item {
            return RemoteManagement.UpdateStatus(
                current: current, latest: item.displayVersionString,
                updateAvailable: true
            )
        }
        return RemoteManagement.UpdateStatus(
            current: current, updateAvailable: false
        )
    }

    /// Answers a client's `update-install` request by running the full
    /// Sparkle flow with the driver in silent mode: download, install, and
    /// relaunch happen on this Mac without any local clicks.
    func installUpdate() async -> RemoteManagement.UpdateStatus {
        let status = await checkUpdateInformation()
        guard status.updateAvailable else { return status }
        // The probe's continuation resumes inside `didFinishUpdateCycleFor`,
        // where the update session has not fully torn down yet: Sparkle still
        // reports `sessionInProgress` and would ignore a `checkForUpdates()`
        // made right now. Wait briefly for the session to end first.
        var attempts = 0
        while updater.sessionInProgress, attempts < 40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        guard !updater.sessionInProgress else {
            return RemoteManagement.UpdateStatus(
                current: status.current, latest: status.latest,
                updateAvailable: true,
                detail: "the previous update session has not finished yet"
            )
        }
        userDriver.beginSilentInstall()
        updater.checkForUpdates()
        return RemoteManagement.UpdateStatus(
            current: status.current, latest: status.latest,
            updateAvailable: true
        )
    }
}
