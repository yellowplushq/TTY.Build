import Foundation
import PedalsKit

/// Server side of the remote hook-management and desktop-update ctl messages
/// (PROTOCOL.md §5): thin orchestration over `HookInstaller`, plus the update
/// status value the host app fills in through its Sparkle-backed handlers.
///
/// Everything here runs off the relay queue (file IO, process probes);
/// `RelayHostClient` bounces the replies back onto its own queue.
public enum RemoteManagement {
    /// Update state reported to paired clients. `current == nil` means the
    /// host cannot name its own version (e.g. headless `pedals serve`).
    public struct UpdateStatus: Sendable {
        public var current: String?
        public var latest: String?
        public var updateAvailable: Bool
        public var detail: String?

        public init(
            current: String? = nil,
            latest: String? = nil,
            updateAvailable: Bool,
            detail: String? = nil
        ) {
            self.current = current
            self.latest = latest
            self.updateAvailable = updateAvailable
            self.detail = detail
        }

        /// Wire form. `canInstall` is always true here: these handlers only
        /// exist when the host app injected its updater.
        public var info: UpdateStatusInfo {
            UpdateStatusInfo(
                current: current, latest: latest,
                updateAvailable: updateAvailable, canInstall: true,
                detail: detail
            )
        }
    }

    /// Sparkle-backed lookup performed by the host app. Called once per
    /// `update-status` / `update-install` client request.
    public typealias UpdateHandler = @Sendable () async -> UpdateStatus

    public enum RemoteError: Error, CustomStringConvertible {
        case unknownAgent(String)
        /// No `pedals-hook` binary next to the running executable.
        case reporterMissing

        public var description: String {
            switch self {
            case .unknownAgent(let slug):
                "unknown agent \"\(slug)\""
            case .reporterMissing:
                "the pedals-hook helper is missing from this build"
            }
        }
    }

    /// The reporter binary embedded next to the running executable (the app
    /// bundle's MacOS directory, or the build products directory for the
    /// headless `pedals` executable).
    public static func bundledReporter() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent()
            .appendingPathComponent("pedals-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Install state of every known agent. A state that cannot be determined
    /// (unreadable settings, unavailable probe) reports as "unknown" rather
    /// than failing the whole list.
    public static func hookStates(
        reporterPath: String, agentHome: URL? = nil
    ) -> [HookStateInfo] {
        HookInstaller.HookedAgent.allCases.map { agent in
            let state: String
            if let resolved = try? HookInstaller.state(
                for: agent, reporterPath: reporterPath, home: agentHome
            ) {
                state = resolved.rawValue
            } else {
                state = "unknown"
            }
            return HookStateInfo(agent: agent.rawValue, state: state)
        }
    }

    /// Refreshes the shared reporter binary, then writes (or rewrites, for an
    /// outdated install) the agent's hook entries. Idempotent.
    public static func installHook(
        agent: String,
        reporterDestination: URL,
        reporterSource: URL? = bundledReporter(),
        agentHome: URL? = nil
    ) throws {
        guard let hooked = HookInstaller.HookedAgent(rawValue: agent) else {
            throw RemoteError.unknownAgent(agent)
        }
        guard let reporterSource else { throw RemoteError.reporterMissing }
        try HookInstaller.installReporterBinary(
            from: reporterSource, to: reporterDestination
        )
        try HookInstaller.install(
            for: hooked, reporterPath: reporterDestination.path, home: agentHome
        )
    }

    public static func uninstallHook(agent: String, agentHome: URL? = nil) throws {
        guard let hooked = HookInstaller.HookedAgent(rawValue: agent) else {
            throw RemoteError.unknownAgent(agent)
        }
        try HookInstaller.uninstall(for: hooked, home: agentHome)
    }
}
