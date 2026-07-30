import Foundation
import PedalsDaemonCore

/// Install state and actions for the "Coding Agents" settings section.
///
/// Installing an agent copies the bundled `pedals-hook` reporter to
/// `~/.pedals/bin/pedals-hook` (a stable path that survives app relocation)
/// and writes sentinel-marked hook entries into the agent's own settings
/// file. The daemon needs no restart: hooks report over the local socket.
@MainActor
final class AgentHooksModel: ObservableObject {
    enum RowState: Equatable {
        case unknown
        case notInstalled
        case installed
        case outdated
    }

    @Published private(set) var states: [HookInstaller.HookedAgent: RowState] = [:]
    @Published var lastError: String?

    private var pollTask: Task<Void, Never>?
    private let reporterDestination = PedalsHome().hookReporterURL

    /// The reporter binary embedded in the app bundle by the build.
    private var bundledReporter: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent().appendingPathComponent("pedals-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func state(of agent: HookInstaller.HookedAgent) -> RowState {
        states[agent] ?? .unknown
    }

    func refresh() {
        var next: [HookInstaller.HookedAgent: RowState] = [:]
        for agent in HookInstaller.HookedAgent.allCases {
            do {
                next[agent] = switch try HookInstaller.state(
                    for: agent, reporterPath: reporterDestination.path
                ) {
                case .installed: .installed
                case .notInstalled: .notInstalled
                case .outdated: .outdated
                }
            } catch {
                next[agent] = .unknown
            }
        }
        states = next
    }

    func startLivePolling() {
        stopLivePolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stopLivePolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func install(_ agent: HookInstaller.HookedAgent) {
        lastError = nil
        guard let bundled = bundledReporter else {
            lastError = "The pedals-hook helper is missing from this build."
            return
        }
        do {
            try HookInstaller.installReporterBinary(
                from: bundled, to: reporterDestination
            )
            try HookInstaller.install(
                for: agent, reporterPath: reporterDestination.path
            )
        } catch {
            lastError = "\(error)"
        }
        refresh()
    }

    func uninstall(_ agent: HookInstaller.HookedAgent) {
        lastError = nil
        do {
            try HookInstaller.uninstall(for: agent)
        } catch {
            lastError = "\(error)"
        }
        refresh()
    }
}
