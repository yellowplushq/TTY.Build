import AppKit
import PedalsDaemonCore
import SwiftUI

/// Settings uses a value-backed `WindowGroup`, not the `Settings` scene: the
/// latter styles its toolbar itself (centered title, no full-height sidebar),
/// which fights the split-view look. Reusing `.main` also preserves the
/// singleton behavior of the former `Window` scene.
enum SettingsWindow: String, Codable, Hashable {
    case main

    static let id = "pedals-settings"
}

@main
struct PedalsMenubarApp: App {
    @NSApplicationDelegateAdaptor(PedalsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(
            "Settings",
            id: SettingsWindow.id,
            for: SettingsWindow.self
        ) { _ in
            SettingsView()
                .environmentObject(appDelegate.updater)
                .environmentObject(appDelegate.permissions)
        } defaultValue: {
            .main
        }
        .handlesExternalEvents(matching: [])
        .windowToolbarStyle(.unified)
        .defaultSize(width: 760, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class PedalsAppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = UpdaterModel()
    let permissions = PermissionsModel()

    private var statusItemController: StatusItemController?
    private var debugSettingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshManagedAgentHooks()
        statusItemController = StatusItemController(
            model: model,
            updater: updater,
            permissions: permissions
        )

        // Dev affordance: land straight in the settings window so local relay
        // runs and UI screenshots don't need the status-item popover. The
        // real WindowGroup scene must render (a plain NSWindow host lays the
        // toolbar out differently), so a throwaway 1×1 bootstrap window calls
        // the same openWindow(id:) action the menu's gear button uses.
        if ProcessInfo.processInfo.environment["PEDALS_OPEN_SETTINGS"] == "1" {
            let opener = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            opener.contentViewController = NSHostingController(rootView: DebugSettingsOpener())
            opener.orderFront(nil)
            debugSettingsWindow = opener
            NSApp.activate(ignoringOtherApps: true)

            // Self-render the settings window to a PNG: capture the composited
            // window pixels (own-process windows are exempt from the
            // screen-recording gate) so sidebar vibrancy renders.
            if let path = ProcessInfo.processInfo.environment["PEDALS_SETTINGS_SNAPSHOT"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let window = NSApp.windows.first(where: {
                        $0.identifier?.rawValue.contains(SettingsWindow.id) == true
                    }) else { return }
                    guard let image = CGWindowListCreateImage(
                        .null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                        [.boundsIgnoreFraming, .bestResolution]
                    ) else { return }
                    let rep = NSBitmapImageRep(cgImage: image)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Managed hooks outlive the app bundle in ~/.pedals/bin. Refresh the
    /// shared reporter and any generated plugin source on launch so a Sparkle
    /// update delivers new parsing/event mappings without opting users into
    /// agents they never enabled.
    private func refreshManagedAgentHooks() {
        guard let executable = Bundle.main.executableURL else { return }
        let bundledReporter = executable.deletingLastPathComponent()
            .appendingPathComponent("pedals-hook")
        guard FileManager.default.isExecutableFile(atPath: bundledReporter.path)
        else { return }
        let reporterDestination = PedalsHome().hookReporterURL
        if FileManager.default.fileExists(atPath: reporterDestination.path) {
            do {
                try HookInstaller.installReporterBinary(
                    from: bundledReporter, to: reporterDestination
                )
            } catch {
                NSLog("Pedals could not refresh the agent reporter: %@", "\(error)")
            }
        }
        do {
            try HookInstaller.refreshManagedCodexInstallation(
                reporterSource: bundledReporter,
                reporterDestination: reporterDestination
            )
        } catch {
            NSLog("Pedals could not refresh managed Codex hooks: %@", "\(error)")
        }
        do {
            try HookInstaller.refreshManagedGeneratedPluginInstallations(
                reporterPath: reporterDestination.path
            )
        } catch {
            NSLog("Pedals could not refresh generated agent plugins: %@", "\(error)")
        }
    }

    /// Pedals is a menu-bar service whose lifetime must not be tied to its
    /// Settings windows.
    /// Explicitly keep the process, status item, and relay service alive when
    /// the user closes Settings; the dedicated Quit actions still terminate.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}

/// Hosted in the 1×1 bootstrap window: opens the real settings WindowGroup
/// through the same environment action the menu uses.
private struct DebugSettingsOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear {
                openWindow(id: SettingsWindow.id, value: SettingsWindow.main)
            }
    }
}
