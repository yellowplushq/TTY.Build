import PedalsKit
import SwiftUI

struct WatchTerminalView: View {
    let session: WatchTerminalSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .topLeading) {
            WatchTerminalContent(
                snapshot: session.snapshot,
                phase: session.phase
            )

            ZStack {
                Circle()
                    .fill(.black.opacity(0.78))
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .onTapGesture { dismiss() }
            .accessibilityElement()
            .accessibilityLabel("Back")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { dismiss() }
            .padding(.leading, 5)
            .padding(.top, 4)
            .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
        ._statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .ignoresSafeArea()
        .task { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Wrist-down stops every link (WatchTerminalStore.stop()); the
            // store's start() only revives control connections, so the open
            // terminal reconnects itself on wake instead of sitting frozen.
            guard phase == .active else { return }
            session.start()
        }
    }
}

private struct WatchTerminalContent: View {
    private struct ScrollState: Equatable {
        let atBottom: Bool
    }

    private struct GridDimensions: Equatable {
        let columns: Int
        let rows: Int
    }

    private enum ScrollTarget: Hashable {
        case blank(Int)
        case line(UInt64)
        case bottom
    }

    /// SF Mono's advance is approximately 0.6 em. Keeping one shared size for
    /// every row preserves terminal columns; the whole grid is scaled to the
    /// available Watch width instead of reflowing individual lines.
    private static let monospacedCellWidthRatio: CGFloat = 0.6
    private static let horizontalPadding: CGFloat = 4

    let snapshot: TerminalTextProjection.Snapshot
    let phase: WatchTerminalSession.Phase

    @State private var pinnedToBottom = true
    @State private var scrollPosition: ScrollTarget? = .bottom

    var body: some View {
        GeometryReader { geometry in
            terminalGrid(width: geometry.size.width)
        }
        .background(.black)
        .overlay(alignment: .topTrailing) {
            phaseIndicator
        }
    }

    private func terminalGrid(width: CGFloat) -> some View {
        let contentWidth = max(1, width - Self.horizontalPadding * 2)
        let fontSize = max(
            0.5,
            contentWidth
                / CGFloat(max(snapshot.columns, 1))
                / Self.monospacedCellWidthRatio
        )
        let viewportLines = snapshot.viewportLines
        let unmaterializedRows = max(0, snapshot.rows - viewportLines.count)

        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewportLines) { line in
                    TerminalGridLineView(
                        line: line,
                        fontSize: fontSize,
                        width: contentWidth
                    )
                    .id(ScrollTarget.line(line.id))
                }

                // A sparse shell screen may not have touched every row yet.
                // Keep those rows as real vertical space so the Watch always
                // represents exactly one `snapshot.rows`-high TTY viewport.
                ForEach(0 ..< unmaterializedRows, id: \.self) { row in
                    TerminalGridLineView(
                        line: .init(id: 0, text: ""),
                        fontSize: fontSize,
                        width: contentWidth
                    )
                    .id(ScrollTarget.blank(row))
                }

                Color.clear
                    .frame(height: 1)
                    .id(ScrollTarget.bottom)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $scrollPosition, anchor: .bottom)
        .onScrollGeometryChange(for: ScrollState.self) { geometry in
            return ScrollState(
                atBottom: geometry.contentSize.height <= geometry.containerSize.height + 1
                    || geometry.visibleRect.maxY >= geometry.contentSize.height - 12
            )
        } action: { _, new in
            pinnedToBottom = new.atBottom
        }
        .onChange(of: snapshot.revision) { _, _ in
            guard pinnedToBottom else { return }
            scrollPosition = .bottom
        }
        .onChange(of: GridDimensions(
            columns: snapshot.columns,
            rows: snapshot.rows
        )) { _, _ in
            // A TTY resize changes the coordinate space for every terminal
            // row. Always leave scrollback browsing and follow the newly
            // resized active screen at its bottom.
            pinnedToBottom = true
            scrollPosition = .bottom
        }
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .connecting, .reconnecting:
            ProgressView()
                .controlSize(.mini)
                .padding(4)
                .background(.black.opacity(0.7), in: Circle())
        case .live:
            EmptyView()
        }
    }
}

private struct TerminalGridLineView: View {
    let line: TerminalTextProjection.Line
    let fontSize: CGFloat
    let width: CGFloat

    var body: some View {
        Text(attributedLine)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: width, alignment: .leading)
            .accessibilityLabel(line.text)
    }

    private var attributedLine: AttributedString {
        var result = AttributedString()
        let runs = line.runs.isEmpty
            ? [TerminalTextProjection.Run(text: " ", style: .init())]
            : line.runs

        for run in runs {
            var value = AttributedString(run.text)
            var foreground = run.style.foreground?.swiftUIColor
            var background = run.style.background?.swiftUIColor
            if run.style.inverted {
                swap(&foreground, &background)
                if foreground == nil { foreground = .black }
                if background == nil { background = PedalsTheme.content }
            }

            value.foregroundColor = (foreground ?? PedalsTheme.content)
                .opacity(run.style.faint ? 0.55 : 1)
            if let background { value.backgroundColor = background }
            var font = Font.system(
                size: fontSize,
                weight: run.style.bold ? .bold : .regular,
                design: .monospaced
            )
            if run.style.italic { font = font.italic() }
            value.font = font
            if run.style.underlined { value.underlineStyle = .single }
            result.append(value)
        }
        return result
    }
}

private extension TerminalTextProjection.Color {
    var swiftUIColor: SwiftUI.Color {
        switch self {
        case .rgb(let red, let green, let blue):
            Self.color(red: red, green: green, blue: blue)
        case .indexed(let index):
            Self.indexedColor(index)
        }
    }

    static func indexedColor(_ index: UInt8) -> SwiftUI.Color {
        let base: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
            (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
            (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
            (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
        ]
        if Int(index) < base.count {
            let value = base[Int(index)]
            return color(red: value.0, green: value.1, blue: value.2)
        }
        if index < 232 {
            let value = Int(index) - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return color(
                red: levels[value / 36],
                green: levels[(value / 6) % 6],
                blue: levels[value % 6]
            )
        }
        let level = UInt8(8 + (Int(index) - 232) * 10)
        return color(red: level, green: level, blue: level)
    }

    static func color(red: UInt8, green: UInt8, blue: UInt8) -> SwiftUI.Color {
        SwiftUI.Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

#if DEBUG
struct WatchTerminalFixtureView: View {
    private static let snapshot: TerminalTextProjection.Snapshot = {
        var projection = TerminalTextProjection(cols: 80, rows: 24)
        let output = ([
            "$ pedals status --verbose --include-all-computers --format human-readable",
            "Connected to Studio Mac through the encrypted Pedals relay.",
            "This eighty-column terminal row keeps every cell and scales to the watch width.",
            "中文、emoji 🖥️ and wide glyphs remain aligned while ANSI styling is removed.",
        ] + (1 ... 18).map { "log \($0): terminal grid rows remain vertically scrollable" })
            .joined(separator: "\r\n")
        projection.feed(Data(output.utf8))
        return projection.snapshot
    }()

    var body: some View {
        NavigationStack {
            WatchTerminalContent(
                snapshot: Self.snapshot,
                phase: .live
            )
        }
    }
}
#endif

#Preview("Terminal") {
    var projection = TerminalTextProjection(cols: 80, rows: 24)
    projection.feed(Data("$ pedals status\n3 TTYs running\n\u{1B}[32mconnected\u{1B}[0m\n".utf8))
    return NavigationStack {
        WatchTerminalContent(
            snapshot: projection.snapshot,
            phase: .live
        )
    }
}
