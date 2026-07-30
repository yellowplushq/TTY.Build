import SwiftUI
@preconcurrency import WidgetKit

private struct WatchTTYEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: TTYStatusSnapshot
}

private struct WatchTTYProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchTTYEntry {
        .init(
            date: .now,
            snapshot: .init(totalRunning: 3, computers: [], updatedAt: .now, sequence: 1)
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping @Sendable (WatchTTYEntry) -> Void
    ) {
        completion(context.isPreview
            ? placeholder(in: context)
            : .init(date: .now, snapshot: StatusSharedStore.snapshot()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping @Sendable (Timeline<WatchTTYEntry>) -> Void
    ) {
        StatusSharedStore.activateObservedWidgetPushEndpoint(.watchWidget)
        PushEndpointRegistrar.requestFlush()
        Task {
            let snapshot: TTYStatusSnapshot
            do {
                snapshot = try await PedalsStatusRuntime.refreshState()
            } catch {
                var cached = StatusSharedStore.snapshot()
                cached.stale = true
                snapshot = cached
            }
            completion(
                Timeline(
                    entries: [.init(date: .now, snapshot: snapshot)],
                    policy: .after(.now.addingTimeInterval(15 * 60))
                )
            )
        }
    }
}

struct WatchTTYCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PedalsStatusConstants.watchWidgetKind,
            provider: WatchTTYProvider()
        ) { entry in
            WatchTTYCountView(entry: entry)
                .foregroundStyle(PedalsTheme.content)
                .tint(PedalsTheme.content)
                .widgetAccentable(false)
                .containerBackground(PedalsTheme.canvas, for: .widget)
        }
        .configurationDisplayName("Running TTYs")
        .description("Your running terminal count.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
        .pushHandler(WatchWidgetPushHandler.self)
    }
}

private struct WatchTTYCountView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchTTYEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Text(entry.snapshot.totalRunning, format: .number)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            }

        case .accessoryCorner:
            Text(entry.snapshot.totalRunning, format: .number)
                .font(.title.bold())
                .monospacedDigit()
                .widgetLabel {
                    Text("TTY")
                }

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Text(entry.snapshot.totalRunning, format: .number)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text("TTY")
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                    if entry.snapshot.agentsWaiting > 0 {
                        Label(
                            "\(entry.snapshot.agentsWaiting) waiting",
                            systemImage: "sparkles"
                        )
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.warning)
                        .lineLimit(1)
                    } else if entry.snapshot.agentsRunning > 0 {
                        Label(
                            "\(entry.snapshot.agentsRunning) agents",
                            systemImage: "sparkles"
                        )
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

        default:
            Text("\(entry.snapshot.totalRunning) TTY")
        }
    }
}
