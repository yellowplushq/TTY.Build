import ActivityKit
import PedalsKit
import SwiftUI
@preconcurrency import WidgetKit

struct TTYStatusEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: TTYStatusSnapshot
    let state: TTYActivityAttributes.ContentState

    init(
        date: Date,
        snapshot: TTYStatusSnapshot,
        state: TTYActivityAttributes.ContentState? = nil
    ) {
        self.date = date
        self.snapshot = snapshot
        self.state = state ?? Self.presentationState(for: snapshot)
    }

    /// The aggregate status response carries the same E2EE agent envelopes a
    /// Live Activity receives, so the widget renders rich agent rows on its
    /// own. A push that landed after the last timeline refresh can still be
    /// newer than the snapshot, so when a Live Activity is present keep
    /// whichever copy is most recent.
    private static func presentationState(
        for snapshot: TTYStatusSnapshot
    ) -> TTYActivityAttributes.ContentState {
        var state = TTYActivityAttributes.ContentState(snapshot: snapshot)
        guard state.totalAgents > 0 else { return state }

        let recent = Activity<TTYActivityAttributes>.activities
            .map(\.content.state)
            .filter {
                $0.recentAgentDisplay != nil || $0.recentAgentSealed != nil
            }
            .max {
                let lhs = $0.recentAgentDisplay?.updatedAt
                    ?? $0.recentAgentUpdatedAt ?? .distantPast
                let rhs = $1.recentAgentDisplay?.updatedAt
                    ?? $1.recentAgentUpdatedAt ?? .distantPast
                return lhs < rhs
            }
        guard let recent else { return state }

        let activityUpdatedAt = recent.recentAgentDisplay?.updatedAt
            ?? recent.recentAgentUpdatedAt ?? .distantPast
        let snapshotUpdatedAt = state.recentAgentUpdatedAt ?? .distantPast
        guard activityUpdatedAt >= snapshotUpdatedAt else { return state }

        state.recentAgentComputerID = recent.recentAgentComputerID
        state.recentAgentState = recent.recentAgentState
        state.recentAgentUpdatedAt = recent.recentAgentUpdatedAt
        state.recentAgentSealed = recent.recentAgentSealed
        state.recentAgentDisplay = recent.recentAgentDisplay
        state.moreAgents = recent.moreAgents
        return state
    }
}

struct TTYStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> TTYStatusEntry {
        .init(
            date: .now,
            snapshot: .init(
                totalRunning: 2,
                computers: [
                    .init(
                        id: "preview",
                        name: "Computer",
                        runningTTYCount: 2,
                        agents: .init(running: 1, waiting: 0),
                        online: true,
                        updatedAt: .now
                    ),
                ],
                updatedAt: .now,
                sequence: 1
            ),
            state: previewState
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping @Sendable (TTYStatusEntry) -> Void
    ) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(.init(date: .now, snapshot: StatusSharedStore.snapshot()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping @Sendable (Timeline<TTYStatusEntry>) -> Void
    ) {
        StatusSharedStore.activateObservedWidgetPushEndpoint(.iOSWidget)
        PushEndpointRegistrar.requestFlush()
        Task {
            let snapshot = await loadSnapshot()
            completion(
                Timeline(
                    entries: [.init(date: .now, snapshot: snapshot)],
                    policy: .after(.now.addingTimeInterval(15 * 60))
                )
            )
        }
    }

    private func loadSnapshot() async -> TTYStatusSnapshot {
        do {
            return try await PedalsStatusRuntime.refreshState()
        } catch {
            var cached = StatusSharedStore.snapshot()
            cached.stale = true
            return cached
        }
    }

    private var previewState: TTYActivityAttributes.ContentState {
        TTYActivityAttributes.ContentState(
            totalRunning: 2,
            agentsRunning: 1,
            agentsWaiting: 1,
            recentAgentComputerID: "preview",
            recentAgentState: "running",
            recentAgentUpdatedAt: .now,
            recentAgentDisplay: .init(content: .init(
                id: "preview",
                agent: "codex",
                state: .running,
                sessionName: "Polish the Widget experience",
                project: "pedals",
                action: "Building PedalsWidgets",
                updatedAt: Date.now.timeIntervalSince1970,
                second: .init(
                    id: "preview-2",
                    agent: "claude",
                    state: .waiting,
                    sessionName: "Review the release notes",
                    message: "Choose how to continue",
                    updatedAt: Date.now.timeIntervalSince1970 - 60
                )
            )),
            onlineComputerCount: 1,
            offlineComputerCount: 0,
            updatedAt: .now,
            sequence: 1
        )
    }
}

struct TTYCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PedalsStatusConstants.phoneWidgetKind,
            provider: TTYStatusProvider()
        ) { entry in
            TTYCountWidgetView(entry: entry)
                .foregroundStyle(PedalsTheme.content)
                .tint(PedalsTheme.content)
                .widgetAccentable(false)
                .containerBackground(PedalsTheme.canvas, for: .widget)
        }
        .configurationDisplayName("Pedals Activity")
        .description("Terminal and coding-agent activity across your paired computers.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
        .pushHandler(IOSWidgetPushHandler.self)
    }
}

private struct TTYCountWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TTYStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircular

        case .accessoryRectangular:
            accessoryRectangular

        case .accessoryInline:
            Text(accessoryInlineText)

        default:
            // Home Screen families render the exact island/Lock Screen card:
            // the same ranked agent rows, terminal fallback, and count
            // summary, with no widget-specific composition.
            ActivityCard(state: entry.state, redactsSensitiveContent: false)
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
    }

    private var presentation: ActivityPresentation {
        ActivityPresentation(state: entry.state)
    }

    @ViewBuilder
    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if presentation.showsAgent {
                VStack(spacing: 1) {
                    AgentMark(presentation: presentation, size: 20)
                        .accessibilityHidden(true)
                    Text(ActivityStyle.compactLabel(for: presentation))
                        .font(.system(size: 8, weight: .bold))
                        .minimumScaleFactor(0.65)
                        .lineLimit(1)
                }
            } else {
                VStack(spacing: 0) {
                    Image(systemName: "terminal.fill")
                        .font(.caption2)
                    Text(entry.state.totalRunning, format: .number)
                        .font(.title3.bold())
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessoryInlineText)
    }

    @ViewBuilder
    private var accessoryRectangular: some View {
        if presentation.showsAgent {
            HStack(alignment: .top, spacing: 7) {
                AgentMark(presentation: presentation, size: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(ActivityStyle.primary(for: presentation, state: entry.state))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(ActivityStyle.compactLabel(for: presentation))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ActivityStyle.color(for: presentation))
                            .lineLimit(1)
                    }
                    Text(ActivityStyle.detail(for: presentation))
                        .font(.caption2)
                        .foregroundStyle(ActivityStyle.color(for: presentation))
                        .lineLimit(2)
                }
            }
            .privacySensitive()
        } else {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(terminalCountText)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("Remote sessions are ready.")
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var accessoryInlineText: String {
        if presentation.showsAgent {
            let title = ActivityStyle.primary(for: presentation, state: entry.state)
            let status = ActivityStyle.compactLabel(for: presentation)
            return "\(title) · \(status)"
        }
        return "Pedals · \(terminalCountText)"
    }

    private var terminalCountText: String {
        entry.state.totalRunning == 1
            ? "1 terminal active"
            : "\(entry.state.totalRunning) terminals active"
    }
}
