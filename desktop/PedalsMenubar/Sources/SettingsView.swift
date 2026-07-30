import AppKit
import PedalsDaemonCore
import SwiftUI

/// Settings window: NavigationSplitView with a native sidebar (supacode's
/// exact structure — sidebar List selection, unified transparent toolbar,
/// grouped-form detail pages pulled to the edges).
struct SettingsView: View {
    enum Page: CaseIterable, Hashable {
        case permissions
        case agents
        case updates
        case about

        var title: String {
            switch self {
            case .permissions: "Permissions"
            case .agents: "Coding Agents"
            case .updates: "Updates"
            case .about: "About"
            }
        }

        var symbolName: String {
            switch self {
            case .permissions: "lock.shield"
            case .agents: "sparkles"
            case .updates: "arrow.down.circle"
            case .about: "info.circle"
            }
        }
    }

    @EnvironmentObject private var updaterModel: UpdaterModel
    @EnvironmentObject private var permissions: PermissionsModel
    @StateObject private var agentHooks = AgentHooksModel()
    @State private var selection: Page = .permissions

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selection) {
                ForEach(Page.allCases, id: \.self) { page in
                    Label(page.title, systemImage: page.symbolName)
                        .tag(page)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection {
            case .permissions:
                PermissionsPage(permissions: permissions)
            case .agents:
                AgentsPage(agentHooks: agentHooks)
            case .updates:
                UpdatesPage(updaterModel: updaterModel)
            case .about:
                AboutPage()
            }
        }
        .toolbar {
            // Invisible item keeps the toolbar stable when switching between
            // detail views with and without toolbar items.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 540)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            // Dev affordance: land on a specific page for snapshots.
            switch ProcessInfo.processInfo.environment["PEDALS_SETTINGS_PAGE"] {
            case "agents": selection = .agents
            case "updates": selection = .updates
            case "about": selection = .about
            case "permissions": selection = .permissions
            default: break
            }
        }
    }

    // MARK: - Permissions

    private struct PermissionsPage: View {
        @ObservedObject var permissions: PermissionsModel

        var body: some View {
            Form {
                Section {
                    Text(Self.explanation)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }

                Section {
                    ForEach(RemotePermission.allCases) { permission in
                        PermissionRow(
                            permission: permission,
                            granted: permissions.isGranted(permission)
                        ) {
                            permissions.request(permission)
                        }
                    }
                } footer: {
                    Text(Self.footnote)
                        .font(.caption)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }
            }
            .formStyle(.grouped)
            .settingsPageInsets()
            .navigationTitle("Permissions")
            .onAppear {
                permissions.refresh()
                permissions.startLivePolling()
            }
            .onDisappear {
                permissions.stopLivePolling()
            }
        }

        private static let explanation = """
            Pedals asks for these up front so programs running in remote \
            terminal sessions can use them without approval prompts appearing \
            on this Mac while you're away. Pedals itself never reads your \
            files, controls your Mac, or records your screen.
            """

        private static let footnote = """
            Grants apply to new sessions. macOS may ask to relaunch Pedals \
            after screen recording is enabled.
            """
    }

    // MARK: - Coding Agents

    private struct AgentsPage: View {
        @ObservedObject var agentHooks: AgentHooksModel

        var body: some View {
            Form {
                Section {
                    Text(Self.explanation)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }

                Section {
                    ForEach(Self.agentRows, id: \.agent) { row in
                        AgentHookRow(
                            assetName: row.asset,
                            title: row.title,
                            detail: row.detail,
                            state: agentHooks.state(of: row.agent),
                            onInstall: { agentHooks.install(row.agent) },
                            onUninstall: { agentHooks.uninstall(row.agent) }
                        )
                    }
                } footer: {
                    if let error = agentHooks.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(PedalsTheme.critical)
                    }
                }
            }
            .formStyle(.grouped)
            .settingsPageInsets()
            .navigationTitle("Coding Agents")
            .onAppear {
                agentHooks.refresh()
                agentHooks.startLivePolling()
            }
            .onDisappear {
                agentHooks.stopLivePolling()
            }
        }

        /// One row per supported agent, in panel order. The detail line names
        /// exactly what gets written where — keep it honest.
        private static let agentRows: [(
            agent: HookInstaller.HookedAgent, asset: String, title: String, detail: String
        )] = [
            (.claude, "claude-code-mark", "Claude Code",
             "Hooks in ~/.claude/settings.json."),
            (.codex, "codex-mark", "Codex",
             "Hooks in ~/.codex/hooks.json; enables the hooks feature in ~/.codex/config.toml."),
            (.copilot, "copilot-mark", "Copilot CLI",
             "Hook file in ~/.copilot/hooks/pedals.json."),
            (.grok, "grok-mark", "Grok",
             "Hook file in ~/.grok/hooks/pedals.json."),
            (.hermes, "hermes-mark", "Hermes",
             "Plugin in ~/.hermes/plugins/pedals-presence/."),
            (.kimi, "kimi-mark", "Kimi Code",
             "Hooks in ~/.kimi-code/config.toml."),
            (.kiro, "kiro-mark", "Kiro",
             "Hooks in ~/.kiro/agents/kiro_default.json. Requires Kiro CLI 2."),
            (.omp, "omp-mark", "Oh My Pi",
             "Extension in ~/.omp/agent/extensions/pedals/."),
            (.opencode, "opencode-mark", "OpenCode",
             "Plugin in ~/.config/opencode/plugins/pedals-presence.js."),
            (.pi, "pi-mark", "Pi",
             "Extension in ~/.pi/agent/extensions/pedals/."),
        ]

        private static let explanation = """
            Pedals can watch coding agents running anywhere on this Mac — any \
            terminal, any editor — and show their status on your iPhone and \
            Apple Watch.
            """
    }

    // MARK: - Updates

    private struct UpdatesPage: View {
        @ObservedObject var updaterModel: UpdaterModel
        @State private var automaticallyChecksForUpdates = true
        @State private var automaticallyDownloadsUpdates = true

        var body: some View {
            Form {
                Section {
                    Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    Toggle(
                        "Download and install updates automatically",
                        isOn: $automaticallyDownloadsUpdates
                    )
                    .disabled(!automaticallyChecksForUpdates)
                    Button("Check for Updates…") {
                        updaterModel.checkForUpdates()
                    }
                    .disabled(!updaterModel.canCheckForUpdates)
                }
            }
            .formStyle(.grouped)
            .settingsPageInsets()
            .navigationTitle("Updates")
            .onAppear {
                automaticallyChecksForUpdates = updaterModel.updater.automaticallyChecksForUpdates
                automaticallyDownloadsUpdates = updaterModel.updater.automaticallyDownloadsUpdates
            }
            .onChange(of: automaticallyChecksForUpdates) { _, value in
                updaterModel.updater.automaticallyChecksForUpdates = value
            }
            .onChange(of: automaticallyDownloadsUpdates) { _, value in
                updaterModel.updater.automaticallyDownloadsUpdates = value
            }
        }
    }

    // MARK: - About

    private struct AboutPage: View {
        var body: some View {
            Form {
                Section {
                    LabeledContent("Version", value: Self.version)
                    Text("Pedals stays available while its menu bar icon is visible.")
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }
            }
            .formStyle(.grouped)
            .settingsPageInsets()
            .navigationTitle("About")
        }

        private static var version: String {
            let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "—"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "—"
            return "\(marketing) (\(build))"
        }
    }

    // MARK: - Rows

    /// One coding agent: logo mark + name/detail + install state control.
    private struct AgentHookRow: View {
        let assetName: String
        let title: String
        let detail: String
        let state: AgentHooksModel.RowState
        let onInstall: () -> Void
        let onUninstall: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                // Rendering intent lives in the asset (supacode's split):
                // colored brand marks are `original`, plain-glyph marks are
                // `template` and pick up the primary tint here.
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .frame(width: 22)
                    .foregroundStyle(PedalsTheme.content)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }
                Spacer()
                switch state {
                case .installed:
                    Menu {
                        Button("Reinstall") { onInstall() }
                        Button("Uninstall") { onUninstall() }
                    } label: {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                case .outdated:
                    Button("Update…") { onInstall() }
                case .notInstalled, .unknown:
                    Button("Install…") { onInstall() }
                }
            }
        }
    }

    private struct PermissionRow: View {
        let permission: RemotePermission
        let granted: Bool
        let onGrant: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: permission.symbolName)
                    .frame(width: 22)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                    Text(permission.detail)
                        .font(.caption)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }
                Spacer()
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant…") {
                        onGrant()
                    }
                }
            }
        }
    }
}

extension View {
    /// supacode's grouped-form fit inside the split-view detail: pull the
    /// form's outer margin back to the pane edges.
    func settingsPageInsets() -> some View {
        padding(.top, -20)
            .padding(.leading, -8)
            .padding(.trailing, -6)
    }
}
