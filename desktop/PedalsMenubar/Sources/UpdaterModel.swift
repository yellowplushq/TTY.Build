import Combine
import PedalsDaemonCore
import Sparkle

/// `SPUUpdater` takes its delegate at init, so the probing-check callbacks
/// land here and are forwarded into `UpdaterModel`'s MainActor state.
private final class UpdaterProbeDelegate: NSObject, SPUUpdaterDelegate {
    var onFound: @MainActor (SUAppcastItem) -> Void = { _ in }
    var onCycleFinished: @MainActor () -> Void = {}

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
        Task { await onCycleFinished() }
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    let updater: SPUUpdater

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private let probeDelegate: UpdaterProbeDelegate

    /// Result of the in-flight `checkForUpdateInformation` probe, delivered
    /// to the pending continuation by `didFinishUpdateCycleForUpdateCheck`.
    private var probeItem: SUAppcastItem?
    private var probeContinuation: CheckedContinuation<SUAppcastItem?, Never>?

    init() {
        let probeDelegate = UpdaterProbeDelegate()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: probeDelegate,
            userDriverDelegate: nil
        )
        self.probeDelegate = probeDelegate
        self.controller = controller
        updater = controller.updater

        probeDelegate.onFound = { [weak self] item in
            self?.probeItem = item
        }
        probeDelegate.onCycleFinished = { [weak self] in
            guard let self, let continuation = self.probeContinuation else { return }
            self.probeContinuation = nil
            let item = self.probeItem
            self.probeItem = nil
            continuation.resume(returning: item)
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
        let item: SUAppcastItem? = await withCheckedContinuation { continuation in
            probeContinuation = continuation
            updater.checkForUpdateInformation()
        }
        if let item {
            return RemoteManagement.UpdateStatus(
                current: current, latest: item.displayVersionString,
                updateAvailable: true
            )
        }
        return RemoteManagement.UpdateStatus(
            current: current, updateAvailable: false
        )
    }

    /// Answers a client's `update-install` request by starting the standard
    /// Sparkle flow on this Mac (it may present UI and relaunch the app).
    func installUpdate() async -> RemoteManagement.UpdateStatus {
        let status = await checkUpdateInformation()
        if status.updateAvailable {
            updater.checkForUpdates()
            return RemoteManagement.UpdateStatus(
                current: status.current, latest: status.latest,
                updateAvailable: true,
                detail: "the updater was opened on this Mac"
            )
        }
        return status
    }
}
