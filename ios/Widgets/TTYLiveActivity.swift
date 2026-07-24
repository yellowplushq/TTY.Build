import ActivityKit
import Foundation
import PedalsKit
import SwiftUI
import WidgetKit

struct TTYLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TTYActivityAttributes.self) { context in
            ActivityCard(state: context.state, stale: context.isStale)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(PedalsTheme.content)
                .activityBackgroundTint(PedalsTheme.canvas)
                .activitySystemActionForegroundColor(PedalsTheme.content)
        } dynamicIsland: { context in
            let state = context.state
            let presentation = ActivityPresentation(state: state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    // Reuse the Lock Screen/Home-row composition as one
                    // full-width unit. Splitting its identity and state into
                    // separate expanded regions lets the bottom region choose
                    // an intrinsic centered width, which is what caused the
                    // conspicuous empty margins in the old island.
                    ActivityCard(state: state, stale: context.isStale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .privacySensitive()
                }
            } compactLeading: {
                CompactMark(presentation: presentation)
            } compactTrailing: {
                CompactValue(state: state, presentation: presentation)
            } minimal: {
                CompactMark(presentation: presentation)
            }
            .keylineTint(ActivityStyle.color(for: presentation))
        }
    }
}

private struct ActivityCard: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let presentation = ActivityPresentation(state: state)
        Group {
            if presentation.showsAgent {
                AgentActivityRow(
                    state: state, presentation: presentation, stale: stale
                )
            } else {
                TerminalActivityCard(state: state, stale: stale)
            }
        }
    }
}

private struct ActivityPresentation {
    let agent: AgentActivity.Content?
    let agentState: AgentState?

    init(state: TTYActivityAttributes.ContentState) {
        let fallbackState = state.displayedAgentState
        let decodedAgent = fallbackState == nil ? nil : state.resolvedRecentAgent
        agent = decodedAgent
        agentState = decodedAgent?.state ?? fallbackState
    }

    var showsAgent: Bool { agentState != nil }

    var agentName: String {
        guard let agent else { return "Agent" }
        return AgentActivity.displayName(forAgent: agent.agent)
    }

    var agentContent: AgentActivity.Presentation? {
        agent.map { AgentActivity.Presentation(content: $0) }
    }
}

/// The same visual anchor as a Home agent row: the real agent mark with its
/// current state sitting on the mark's top-right corner.
private struct AgentMark: View {
    let presentation: ActivityPresentation
    var size: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var workingBadgeDimmed = false

    var body: some View {
        let badgeSize: CGFloat = size >= 22 ? 10 : 8
        ZStack(alignment: .topLeading) {
            if let agent = presentation.agent,
               let asset = ActivityStyle.asset(for: agent.agent)
            {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .offset(y: 4)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .frame(width: size, height: size)
                    .offset(y: 4)
            }

            if let agentState = presentation.agentState, agentState != .done {
                Circle()
                    .fill(ActivityStyle.color(for: presentation))
                    .frame(width: badgeSize, height: badgeSize)
                    .overlay {
                        Circle()
                            .stroke(PedalsTheme.canvas, lineWidth: size >= 22 ? 2 : 1.5)
                    }
                    .offset(x: size - badgeSize / 2 - 1)
                    .opacity(
                        agentState == .running && workingBadgeDimmed ? 0.25 : 1
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size + 4, height: size + 4, alignment: .topLeading)
        .foregroundStyle(PedalsTheme.content)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(presentation.agentName), \(ActivityStyle.label(for: presentation))"
        )
        .onAppear {
            updateWorkingBadgeAnimation()
        }
        .onChange(of: presentation.agentState) { _, _ in
            updateWorkingBadgeAnimation()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateWorkingBadgeAnimation()
        }
    }

    private func updateWorkingBadgeAnimation() {
        withAnimation(.none) {
            workingBadgeDimmed = false
        }
        guard presentation.agentState == .running, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            workingBadgeDimmed = true
        }
    }
}

private struct AgentIdentity: View {
    let presentation: ActivityPresentation

    var body: some View {
        HStack(spacing: 7) {
            AgentMark(presentation: presentation)
                .accessibilityHidden(true)
            Text(presentation.agentName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(presentation.agentName), \(ActivityStyle.label(for: presentation))"
        )
    }
}

private struct TerminalIdentity: View {
    var body: some View {
        Label("Pedals", systemImage: "terminal.fill")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
    }
}

/// Text instead of a filled capsule keeps the expanded island at the same
/// visual weight as Home's trailing relative time.
private struct ActivityStateLabel: View {
    let presentation: ActivityPresentation

    var body: some View {
        Text(ActivityStyle.label(for: presentation))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ActivityStyle.color(for: presentation))
            .lineLimit(1)
    }
}

private struct ActivityBody: View {
    let state: TTYActivityAttributes.ContentState
    let presentation: ActivityPresentation
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if presentation.showsAgent {
                Text(ActivityStyle.primary(for: presentation, state: state))
                    .font(.headline)
                    .lineLimit(1)
                Text(ActivityStyle.detail(for: presentation))
                    .font(.subheadline)
                    .foregroundStyle(ActivityStyle.color(for: presentation))
                    .lineLimit(2)
            } else {
                Text(state.totalRunning == 1 ? "1 terminal active" : "\(state.totalRunning) terminals active")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("Remote sessions are ready when you are.")
                    .font(.subheadline)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .lineLimit(1)
            }

            ActivityMetrics(state: state, stale: stale)
        }
        .privacySensitive()
    }
}

/// Lock Screen form of the Home agent list item: icon and state badge leading,
/// session name over the latest output/action, metadata trailing.
private struct AgentActivityRow: View {
    let state: TTYActivityAttributes.ContentState
    let presentation: ActivityPresentation
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark(presentation: presentation)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ActivityStyle.primary(for: presentation, state: state))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ActivityStateLabel(presentation: presentation)
                }
                Text(ActivityStyle.detail(for: presentation))
                    .font(.subheadline)
                    .foregroundStyle(ActivityStyle.color(for: presentation))
                    .lineLimit(2)
                ActivityMetrics(state: state, stale: stale)
            }
            .privacySensitive()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.agentName)
        .accessibilityValue(
            "\(ActivityStyle.label(for: presentation)), "
                + "\(ActivityStyle.primary(for: presentation, state: state)), "
                + ActivityStyle.detail(for: presentation)
        )
    }
}

private struct TerminalActivityCard: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TerminalIdentity()
                Spacer(minLength: 8)
                Text("Live")
                    .font(.caption2.weight(.semibold))
            }
            ActivityBody(
                state: state, presentation: ActivityPresentation(state: state), stale: stale
            )
        }
    }
}

private struct ActivityMetrics: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let summary = state.activityCountSummary {
                Text(summary)
            }
            if stale {
                Text("Updating…")
            }
        }
        .font(.caption2)
        .foregroundStyle(PedalsTheme.secondaryContent)
        .lineLimit(1)
    }
}

private struct CompactMark: View {
    let presentation: ActivityPresentation

    var body: some View {
        Group {
            if presentation.showsAgent {
                AgentMark(presentation: presentation, size: 17)
            } else {
                Image(systemName: "terminal.fill")
                    .frame(width: 17, height: 17)
            }
        }
        .foregroundStyle(PedalsTheme.content)
        .accessibilityLabel(ActivityStyle.label(for: presentation))
    }
}

private struct CompactValue: View {
    let state: TTYActivityAttributes.ContentState
    let presentation: ActivityPresentation

    var body: some View {
        Group {
            if presentation.showsAgent {
                Text(ActivityStyle.compactLabel(for: presentation))
                    .font(.caption2.weight(.bold))
            } else {
                Text(state.totalRunning, format: .number)
                .fontWeight(.bold)
                .monospacedDigit()
                .contentTransition(.numericText())
            }
        }
        .foregroundStyle(ActivityStyle.color(for: presentation))
        .accessibilityLabel(ActivityStyle.label(for: presentation))
    }
}

private enum ActivityStyle {
    static func label(for presentation: ActivityPresentation) -> String {
        switch presentation.agentState {
        case .waiting: "Needs you"
        case .error: "Error"
        case .done: "Finished"
        case .running: "Working"
        case nil: "Live"
        }
    }

    static func compactLabel(for presentation: ActivityPresentation) -> String {
        switch presentation.agentState {
        case .waiting: "Needs you"
        case .error: "Error"
        case .done: "Done"
        case .running: "Working"
        case nil: "Live"
        }
    }

    static func color(for presentation: ActivityPresentation) -> Color {
        switch presentation.agentState {
        case .waiting: PedalsTheme.warning
        case .error: PedalsTheme.critical
        case .done: PedalsTheme.success
        case .running: PedalsTheme.content
        case nil: PedalsTheme.content
        }
    }

    static func primary(
        for presentation: ActivityPresentation,
        state: TTYActivityAttributes.ContentState
    ) -> String {
        guard let agent = presentation.agent else {
            if state.totalAgents > 1 {
                return "\(state.totalAgents) agents"
            }
            return switch presentation.agentState {
            case .waiting: "Agent needs you"
            case .error: "Agent error"
            case .done: "Agent finished"
            case .running: "Agent working"
            case nil: "Agent"
            }
        }
        return presentation.agentContent?.title
            ?? AgentActivity.displayName(forAgent: agent.agent)
    }

    static func detail(for presentation: ActivityPresentation) -> String {
        guard presentation.agent != nil else {
            return fallbackDetail(for: presentation.agentState)
        }
        return presentation.agentContent?.detail
            ?? fallbackDetail(for: presentation.agentState)
    }

    private static func fallbackDetail(for state: AgentState?) -> String {
        switch state {
        case .running: "Working…"
        case .waiting: "Waiting for your input"
        case .error: "Agent hit an error"
        case .done: "Task completed"
        case nil: "Agent activity is updating…"
        }
    }

    static func asset(for slug: String) -> String? {
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
