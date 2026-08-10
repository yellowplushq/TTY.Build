import SwiftUI

struct WatchRootView: View {
    @Environment(WatchTerminalStore.self) private var terminalStore
    @State private var presentedTerminal: WatchTerminalDescriptor?

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TTYBUILD_WATCH_TERMINAL_FIXTURE"] == "1" {
            WatchTerminalFixtureView()
        } else {
            terminalNavigation
        }
        #else
        terminalNavigation
        #endif
    }

    private var terminalNavigation: some View {
        NavigationStack {
            WatchStatusView { presentedTerminal = $0 }
        }
        .fullScreenCover(item: $presentedTerminal) { descriptor in
            if let session = terminalStore.session(for: descriptor) {
                WatchTerminalView(session: session)
            } else {
                ContentUnavailableView(
                    "Terminal unavailable",
                    systemImage: "terminal",
                    description: Text("Return to the terminal list and try again.")
                )
            }
        }
        .onChange(of: terminalStore.terminalListRevision) { _, _ in
            guard let currentTerminal = presentedTerminal else { return }
            guard terminalStore.descriptor(for: currentTerminal.id)?.alive != true else {
                return
            }
            presentedTerminal = nil
        }
    }
}
