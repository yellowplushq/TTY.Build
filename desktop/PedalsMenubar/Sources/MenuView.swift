import AppKit
import PedalsKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: UpdaterModel
    @EnvironmentObject private var permissions: PermissionsModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingPairingCode = false
    #if DEBUG
    @State private var openedSettingsForTesting = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.hasPairedDevice {
                sessionList
                if showingPairingCode {
                    Divider()
                    pairingSection
                }
                if !permissions.allGranted {
                    Divider()
                    permissionsReminder
                }
                if let error = model.lastError {
                    Divider()
                    ErrorBanner(message: error)
                }
            } else {
                DesktopPairingView()
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .font(PedalsTheme.text)
        .background(PedalsTheme.canvas)
        .tint(PedalsTheme.content)
        .onAppear {
            permissions.refresh()
            #if DEBUG
            if !openedSettingsForTesting,
               ProcessInfo.processInfo.environment["PEDALS_OPEN_SETTINGS_FROM_MENU"] == "1" {
                openedSettingsForTesting = true
                openWindow(id: SettingsWindow.id, value: SettingsWindow.main)
            }
            #endif
        }
        .onDisappear {
            showingPairingCode = false
            model.schedulePairingRevocationAfterDefocus()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pedals")
                    .font(PedalsTheme.emphasizedText)
                Text(statusLine)
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }

            Spacer()

            Button {
                openWindow(id: SettingsWindow.id, value: SettingsWindow.main)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusLine: String {
        if model.clientConnected { return "iPhone connected" }
        return model.relayState.label
    }

    // MARK: Sessions

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sessions.isEmpty {
                Text(model.serviceRunning ? "No sessions" : "Starting Pedals…")
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                ForEach(model.sessions, id: \.id) { session in
                    SessionRow(session: session) {
                        model.closeSession(session.id)
                    }
                }
            }

            Divider()

            HStack(spacing: 14) {
                Button {
                    showingPairingCode.toggle()
                    if showingPairingCode {
                        model.presentPairingCode()
                    } else {
                        model.clearPairingCode()
                    }
                } label: {
                    Label(showingPairingCode ? "Hide Code" : "Connect iPhone", systemImage: "number")
                }

                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.serviceRunning)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    // MARK: Permissions

    private var permissionsReminder: some View {
        Button {
            openWindow(id: SettingsWindow.id, value: SettingsWindow.main)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PedalsTheme.warning)
                    .frame(width: 16)
                Text("Finish permission setup for remote sessions")
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(PedalsTheme.content)
        .help("Grant permissions so remote sessions never hit approval prompts")
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var pairingSection: some View {
        DesktopPairingPanel(
            code: model.pairingCode,
            expiresAt: model.pairingExpiresAt,
            isLoading: model.isLoadingPairingCode,
            onRefresh: model.fetchPairingCode
        )
        .padding(12)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Spacer()
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SessionRow: View {
    let session: SessionInfo
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(session.alive ? PedalsTheme.content : PedalsTheme.tertiaryContent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .lineLimit(1)
                Text(subtitle)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("Close session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !session.cwd.isEmpty {
            parts.append((session.cwd as NSString).abbreviatingWithTildeInPath)
        }
        if !session.alive { parts.append("exited") }
        return parts.isEmpty ? "session \(session.id)" : parts.joined(separator: " · ")
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(PedalsTheme.critical)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
    }
}
