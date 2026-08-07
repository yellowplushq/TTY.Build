import SwiftUI

@main
struct PedalsWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WatchTerminalStore.shared)
                .task { WatchTerminalStore.shared.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Wrist-down parks the links instead of tearing them
                    // down: the relay poll session and E2EE state survive a
                    // short suspension, so wrist-up skips the multi-round
                    // handshake and just resumes + replays.
                    switch phase {
                    case .active:
                        WatchTerminalStore.shared.resume()
                    case .inactive, .background:
                        WatchTerminalStore.shared.suspend()
                    @unknown default:
                        WatchTerminalStore.shared.suspend()
                    }
                }
        }
    }
}
