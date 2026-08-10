import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// TCC permissions granted to TTYBuild ahead of time so that programs running
/// inside remote terminal sessions inherit them instead of hitting approval
/// prompts while the user is away. Attribution works because `TTYBuildService`
/// runs inside this process and sessions are its child processes; if the
/// daemon ever moves out to a launchd agent, these grants stop covering
/// sessions and must be made against the daemon binary instead.
enum RemotePermission: String, CaseIterable, Identifiable {
    case fullDiskAccess
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen & System Audio Recording"
        }
    }

    var detail: String {
        switch self {
        case .fullDiskAccess: "Read files anywhere on disk"
        case .accessibility: "Control apps and input"
        case .screenRecording: "Capture the screen and audio"
        }
    }

    var symbolName: String {
        switch self {
        case .fullDiskAccess: "internaldrive"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    fileprivate var settingsPaneURL: URL {
        let pane = switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    fileprivate var promptedDefaultsKey: String {
        "requestedRemotePermission_\(rawValue)V1"
    }
}

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var granted: [RemotePermission: Bool] = [:]

    private var pollingTask: Task<Void, Never>?

    var allGranted: Bool {
        RemotePermission.allCases.allSatisfy { granted[$0] == true }
    }

    init() {
        refresh()
    }

    func isGranted(_ permission: RemotePermission) -> Bool {
        granted[permission] == true
    }

    func refresh() {
        let statuses: [RemotePermission: Bool] = [
            .fullDiskAccess: Self.probeFullDiskAccess(),
            .accessibility: AXIsProcessTrusted(),
            .screenRecording: CGPreflightScreenCaptureAccess(),
        ]
        if statuses != granted {
            granted = statuses
        }
    }

    /// The native prompts only ever appear once per permission, so trigger
    /// them on the first attempt (which also lists TTYBuild in the matching
    /// System Settings pane) and jump straight to that pane afterwards.
    func request(_ permission: RemotePermission) {
        guard !isGranted(permission) else { return }
        let defaults = UserDefaults.standard
        let promptedBefore = defaults.bool(forKey: permission.promptedDefaultsKey)
        defaults.set(true, forKey: permission.promptedDefaultsKey)

        switch permission {
        case .fullDiskAccess:
            // There is no prompt API for Full Disk Access; the probe read
            // registers the attempt with TCC and the user flips the switch
            // in System Settings.
            _ = Self.probeFullDiskAccess()
            NSWorkspace.shared.open(permission.settingsPaneURL)
        case .accessibility:
            if promptedBefore {
                NSWorkspace.shared.open(permission.settingsPaneURL)
            } else {
                // Literal value of kAXTrustedCheckOptionPrompt, which Swift 6
                // rejects as a concurrency-unsafe global var.
                let promptKey = "AXTrustedCheckOptionPrompt"
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
        case .screenRecording:
            if promptedBefore {
                NSWorkspace.shared.open(permission.settingsPaneURL)
            } else {
                _ = CGRequestScreenCaptureAccess()
            }
        }
    }

    func startLivePolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    func stopLivePolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Full Disk Access has no status API. Opening a TCC-protected file is
    /// the standard heuristic: EPERM/EACCES means TCC blocked it, success
    /// means the grant is in place. Several probes guard against a path
    /// missing on a fresh account.
    private nonisolated static func probeFullDiskAccess() -> Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Safari/CloudTabs.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno != ENOENT {
                return false
            }
        }
        return false
    }
}
