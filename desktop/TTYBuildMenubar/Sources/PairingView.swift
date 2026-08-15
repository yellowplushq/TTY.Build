import AppKit
import SwiftUI

/// The first screen on an unpaired computer. There is intentionally no
/// desktop onboarding step before this pairing surface.
struct DesktopPairingView: View {
    @EnvironmentObject private var model: AppModel

    private var pairingReady: Bool {
        model.serviceRunning && model.relayState == .connected && !model.clientConnected
    }

    var body: some View {
        Group {
            if model.isStartingService {
                progress(
                    title: "Starting TTY.Build",
                    detail: "Preparing a secure connection…"
                )
            } else if !model.serviceRunning {
                unavailable
            } else if model.relayState != .connected {
                progress(
                    title: "Connecting",
                    detail: "Your connection code will appear shortly."
                )
            } else {
                pairing
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .task(id: pairingReady) {
            if pairingReady {
                model.presentPairingCode()
            }
        }
    }

    private var pairing: some View {
        VStack(spacing: 12) {
            DesktopPairingPanel(
                code: model.pairingCode,
                expiresAt: model.pairingExpiresAt,
                isLoading: model.isLoadingPairingCode,
                onRefresh: model.fetchPairingCode
            )
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(TTYBuildTheme.critical)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func progress(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(TTYBuildTheme.emphasizedText)
                .foregroundStyle(TTYBuildTheme.content)
            Text(detail)
                .foregroundStyle(TTYBuildTheme.secondaryContent)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 34)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(TTYBuildTheme.secondaryContent)
            Text("TTY.Build couldn’t start")
                .font(TTYBuildTheme.emphasizedText)
                .foregroundStyle(TTYBuildTheme.content)
            Text(model.lastError ?? "Try starting the app again.")
                .foregroundStyle(TTYBuildTheme.secondaryContent)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                model.retryService()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 22)
    }
}

struct DesktopPairingPanel: View {
    let code: String?
    let expiresAt: Date?
    let isLoading: Bool
    let onRefresh: () -> Void

    private static let appStoreURL = URL(
        string: "https://apps.apple.com/us/app/tty-build-agents-terminal/id6792312114"
    )!

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Connect your iPhone")
                    .font(TTYBuildTheme.emphasizedText)
                    .foregroundStyle(TTYBuildTheme.content)
                Text("Open TTY.Build on iPhone and enter this one-time code.")
                    .foregroundStyle(TTYBuildTheme.secondaryContent)
                    .multilineTextAlignment(.center)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TTYBuildTheme.canvas)
                .frame(height: 70)
                .overlay {
                    if let code {
                        Text(formatted(code))
                            .font(TTYBuildTheme.emphasizedText.monospaced())
                            .tracking(3)
                            .foregroundStyle(TTYBuildTheme.content)
                            .accessibilityLabel("Pairing code \(code)")
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Code unavailable")
                            .foregroundStyle(TTYBuildTheme.tertiaryContent)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TTYBuildTheme.separator, lineWidth: 1)
                }

            HStack(spacing: 14) {
                Button {
                    copy(code)
                } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                }
                .disabled(code == nil)

                Button(action: onRefresh) {
                    Label("New Code", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if let expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(remaining(until: expiresAt, now: context.date), systemImage: "clock")
                }
                .foregroundStyle(TTYBuildTheme.tertiaryContent)
            } else {
                Label("Single-use · valid for 15 minutes", systemImage: "clock")
                    .foregroundStyle(TTYBuildTheme.tertiaryContent)
            }

            Divider()

            Button {
                NSWorkspace.shared.open(Self.appStoreURL)
            } label: {
                Label("Get TTY.Build on the App Store", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(TTYBuildTheme.secondaryContent)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(TTYBuildTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(TTYBuildTheme.separator, lineWidth: 1)
        }
    }

    private func copy(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func formatted(_ value: String) -> String {
        guard value.count == 8 else { return value }
        return "\(value.prefix(4))  \(value.suffix(4))"
    }

    private func remaining(until expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now)))
        return String(format: "Expires in %02d:%02d", seconds / 60, seconds % 60)
    }
}
