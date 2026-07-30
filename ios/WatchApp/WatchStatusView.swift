import Combine
import PedalsKit
import SwiftUI

struct WatchStatusView: View {
    let openTerminal: (WatchTerminalDescriptor) -> Void

    @Environment(WatchTerminalStore.self) private var terminalStore
    @State private var snapshot = StatusSharedStore.snapshot()
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(PedalsTheme.content)

                Text(snapshot.totalRunning, format: .number)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())

                Text(snapshot.totalRunning == 1 ? "TTY running" : "TTYs running")
                    .font(.headline)

                HStack(spacing: 10) {
                    Label("\(snapshot.onlineComputerCount)", systemImage: "desktopcomputer")
                    if snapshot.offlineComputerCount > 0 {
                        Label("\(snapshot.offlineComputerCount)", systemImage: "wifi.slash")
                            .foregroundStyle(PedalsTheme.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(PedalsTheme.secondaryContent)

                if snapshot.stale {
                    Text("Waiting for an update")
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.warning)
                } else {
                    Text(snapshot.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }

                terminalLinks
                agentRows
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(PedalsTheme.content)
        .tint(PedalsTheme.content)
        .navigationTitle("Pedals")
        .task {
            terminalStore.retryConnections()
            WatchStatusBridge.shared.requestCurrentContext()
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: StatusSharedStore.didChange)) { _ in
            snapshot = StatusSharedStore.snapshot()
        }
    }

    @ViewBuilder
    private var terminalLinks: some View {
        Divider()
            .padding(.vertical, 4)

        if !terminalStore.hasCredentials {
            Label("Open Pedals on iPhone", systemImage: "iphone.and.arrow.forward")
                .font(.caption)
                .foregroundStyle(PedalsTheme.secondaryContent)
                .multilineTextAlignment(.center)
        } else if terminalStore.computers.allSatisfy({ $0.terminals.isEmpty }) {
            if terminalStore.computers.contains(where: { !$0.ready }) {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Connecting…")
                }
                .font(.caption)
                .foregroundStyle(PedalsTheme.secondaryContent)
            } else {
                Text("No terminals available")
                    .font(.caption)
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }
        } else {
            ForEach(terminalStore.computers) { computer in
                if !computer.terminals.isEmpty {
                    Text(computer.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PedalsTheme.secondaryContent)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(computer.terminals) { terminal in
                        Button {
                            openTerminal(terminal)
                        } label: {
                            HStack(spacing: 6) {
                                if let state = terminal.agentState {
                                    AgentMarkBadgeView(
                                        slug: terminal.agentSlug, state: state, size: 16
                                    )
                                } else {
                                    Image(systemName: terminal.alive ? "terminal.fill" : "xmark.circle")
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(terminal.title)
                                        .lineLimit(1)
                                    if let state = terminal.agentState,
                                       let detail = terminal.agentDetail {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(agentDetailTint(state))
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }
                        .accessibilityLabel("Open terminal \(terminal.title) on \(computer.name)")
                    }
                }
            }
        }
    }

    /// Standalone Agents section, mirroring the iPhone Home list: state-dot
    /// column, attention-first sorting, state-colored detail, long-press
    /// dismissal, and a Clear control for everything not working.
    @ViewBuilder
    private var agentRows: some View {
        let rows = terminalStore.computers
            .flatMap { computer in
                computer.agents.map { (computer: computer, info: $0) }
            }
            .sorted { lhs, rhs in
                let l = Self.attentionRank(lhs.info.state)
                let r = Self.attentionRank(rhs.info.state)
                return l != r ? l < r : lhs.info.updatedAt > rhs.info.updatedAt
            }
        if !rows.isEmpty {
            Divider()
                .padding(.vertical, 4)
            HStack {
                Text("Agents")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PedalsTheme.secondaryContent)
                Spacer()
                if rows.contains(where: { $0.info.state != .running }) {
                    Button {
                        for row in rows where row.info.state != .running {
                            terminalStore.dismissAgent(
                                computerID: row.computer.id, agentID: row.info.id
                            )
                        }
                    } label: {
                        Text("Clear")
                            .font(.caption2)
                            .foregroundStyle(PedalsTheme.tertiaryContent)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(rows, id: \.info.id) { row in
                HStack(alignment: .center, spacing: 6) {
                    AgentMarkBadgeView(
                        slug: row.info.agent, state: row.info.state, size: 16
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        let presentation = AgentActivity.Presentation(info: row.info)
                        Text(presentation.title)
                            .lineLimit(1)
                        Text(presentation.detail)
                            .font(.caption2)
                            .foregroundStyle(agentDetailTint(row.info.state))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .opacity(row.computer.online ? 1 : 0.5)
                .contentShape(Rectangle())
                .contextMenu {
                    Button(role: .destructive) {
                        terminalStore.dismissAgent(
                            computerID: row.computer.id, agentID: row.info.id
                        )
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                }
            }
        }
    }

    /// Attention first: waiting > error > running > done (same order as
    /// the iPhone Home list).
    private static func attentionRank(_ state: AgentState) -> Int {
        switch state {
        case .waiting: 0
        case .error: 1
        case .running: 2
        case .done: 3
        }
    }

    private func agentDetailTint(_ state: AgentState) -> Color {
        switch state {
        case .waiting: PedalsTheme.warning
        case .error: PedalsTheme.critical
        case .running: PedalsTheme.content
        case .done: PedalsTheme.success
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let fresh = try? await PedalsStatusRuntime.refreshState() {
            snapshot = fresh
        } else {
            snapshot = StatusSharedStore.snapshot()
        }
    }
}


/// An agent's brand mark with a state badge on its top-right corner —
/// the same design the iPhone Home rows use. Working blinks slowly.
struct AgentMarkBadgeView: View {
    let slug: String?
    let state: AgentState
    var size: CGFloat = 16

    @State private var dimmed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let asset = slug.flatMap(Self.assetName) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(PedalsTheme.content)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size - 4))
                    .frame(width: size, height: size)
                    .foregroundStyle(PedalsTheme.content)
            }
            // Finished shows no badge — a settled agent needs no marker.
            if state != .done {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    .offset(x: 3, y: -3)
                    .opacity(state == .running && dimmed ? 0.25 : 1)
            }
        }
        .onAppear { startBlinkIfNeeded() }
        .onChange(of: state) { _, _ in startBlinkIfNeeded() }
    }

    private var badgeColor: Color {
        switch state {
        case .waiting: PedalsTheme.warning
        case .error: PedalsTheme.critical
        case .running: PedalsTheme.content
        case .done: PedalsTheme.success
        }
    }

    private func startBlinkIfNeeded() {
        guard state == .running else {
            dimmed = false
            return
        }
        dimmed = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }

    private static func assetName(_ slug: String) -> String? {
        switch slug {
        case "claude": "claude-code-mark"
        case "codex": "codex-mark"
        case "copilot": "copilot-mark"
        case "grok": "grok-mark"
        case "hermes": "hermes-mark"
        case "kimi": "kimi-mark"
        case "kiro": "kiro-mark"
        case "omp": "omp-mark"
        case "opencode": "opencode-mark"
        case "pi": "pi-mark"
        default: nil
        }
    }
}
