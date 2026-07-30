import Combine
import PedalsKit
import UIKit

/// The leftmost page of the main screen: a calm black/white overview of every
/// terminal and every observed coding agent across all bound computers
/// (docs/AGENT_MONITORING_DESIGN.md §4). Terminal rows open their terminal;
/// agent rows are glanceable only. An agent renders in exactly one place:
/// inside its terminal row when its daemon PTY is a live tab, in the Agents
/// section otherwise.
@MainActor
final class HomeViewController: UIViewController {
    var onSelectTerminal: ((TerminalID) -> Void)?
    var onSettings: (() -> Void)?

    private let manager: TerminalManager
    private var cancellables: Set<AnyCancellable> = []

    private enum Section: Int, CaseIterable {
        case terminals
        case agents

        var title: String {
            switch self {
            case .terminals: "Terminals"
            case .agents: "Agents"
            }
        }
    }

    private struct AgentKey: Hashable {
        let computerID: String
        let agentID: String
    }

    private enum Item: Hashable {
        case terminal(TerminalID)
        case agent(AgentKey)
        case terminalsEmpty
        case agentsEmpty
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rowContents: [Item: HomeRowContent] = [:]
    /// Optimistic dismissal overlay (not persisted): a swiped agent hides
    /// immediately while the dismissal travels to the daemon; the entry
    /// prunes once the daemon's broadcast confirms the removal, and a row
    /// that comes back in a different state (dismissal raced a new event)
    /// shows again.
    private var dismissedAgents: [AgentKey: AgentState] = [:]

    /// Latest emissions, kept so the periodic clock tick can re-render
    /// relative times without waiting for a model change.
    private var lastTerminals: [Terminal] = []
    private var lastAgentRows: [AgentRow] = []
    private var lastUnmanaged: [AgentRow] = []
    private var lastComputerCount = 0

    private let settingsButton = UIButton(type: .system)
    private var collectionView: UICollectionView!

    #if DEBUG
    /// Dev-only visual fixture (`PEDALS_HOME_AGENTS_FIXTURE=1`): realistic
    /// agent rows with varied states and ages, since daemon-injected events
    /// always stamp "now". Ages are fixed at launch and grow naturally.
    private static let agentFixtureRows: [AgentRow]? = {
        guard ProcessInfo.processInfo.environment["PEDALS_HOME_AGENTS_FIXTURE"] == "1"
        else { return nil }
        let now = Date().timeIntervalSince1970
        func row(
            _ agent: String, _ state: AgentState, sessionName: String,
            cwd: String, age: Double,
            prompt: String? = nil, message: String? = nil, action: String? = nil
        ) -> AgentRow {
            AgentRow(
                computerID: "fixture", computerName: "Studio", hostOnline: true,
                info: AgentInfo(
                    id: "fx-\(agent)", agent: agent, state: state,
                    sessionName: sessionName, cwd: cwd,
                    action: action, message: message, prompt: prompt,
                    updatedAt: now - age
                )
            )
        }
        return [
            row(
                "claude", .waiting, sessionName: "Polish agent monitoring",
                cwd: "/Users/eyhn/Projects/yellowplus/pedals",
                age: 3 * 60,
                prompt: "把设置页改成侧边栏布局",
                message: "Claude needs your permission to use Bash"
            ),
            row(
                "codex", .running, sessionName: "Website release",
                cwd: "/Users/eyhn/Projects/website",
                age: 6 * 60, action: "Bash: npm run build"
            ),
            row(
                "pi", .running, sessionName: "API cleanup",
                cwd: "/Users/eyhn/Projects/api-server",
                age: 70, action: "Edit: routes.ts"
            ),
            row(
                "kiro", .done, sessionName: "Landing page",
                cwd: "/Users/eyhn/Projects/blog",
                age: 60 * 60, message: "Deployed the new landing page."
            ),
            row(
                "grok", .error, sessionName: "Model experiments",
                cwd: "/Users/eyhn/Projects/experiments",
                age: 3 * 60 * 60, message: "API rate limit exceeded"
            ),
        ]
    }()
    #endif

    init(manager: TerminalManager) {
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PedalsTheme.uiCanvas
        view.accessibilityIdentifier = "pedals.home"
        buildLayout()
        buildDataSource()
        bind()
    }

    // MARK: - Layout

    private func buildLayout() {
        settingsButton.setImage(
            UIImage(
                systemName: "gearshape.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            ),
            for: .normal
        )
        settingsButton.tintColor = PedalsTheme.uiSecondaryContent
        settingsButton.accessibilityIdentifier = "pedals.home.settings"
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.addAction(
            UIAction { [weak self] _ in self?.onSettings?() }, for: .touchUpInside
        )

        // The app title lives in the tab strip while no tabs exist; this
        // row keeps only the settings control.
        let headerRow = UIView()
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            settingsButton.trailingAnchor.constraint(
                equalTo: headerRow.trailingAnchor, constant: -20
            ),
            settingsButton.topAnchor.constraint(equalTo: headerRow.topAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 44),
            settingsButton.heightAnchor.constraint(equalToConstant: 44),
        ])


        collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: makeCollectionLayout()
        )
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "pedals.home.list"

        let stack = UIStackView(arrangedSubviews: [headerRow, collectionView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeCollectionLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            let contentInsets = NSDirectionalEdgeInsets(
                top: 6, leading: 16, bottom: 22, trailing: 16
            )
            if Section(rawValue: sectionIndex) == .agents {
                // A list section so agent rows get the native interactive
                // swipe (leading = rightward, the opposite direction of the
                // page-switch gesture, which slides left toward the
                // terminals). It tracks the finger and springs back below
                // the commit threshold.
                var config = UICollectionLayoutListConfiguration(appearance: .plain)
                config.backgroundColor = .clear
                config.showsSeparators = false
                config.headerMode = .supplementary
                config.leadingSwipeActionsConfigurationProvider = { indexPath in
                    self?.agentSwipeConfiguration(at: indexPath)
                }
                let section = NSCollectionLayoutSection.list(
                    using: config, layoutEnvironment: environment
                )
                section.contentInsets = contentInsets
                return section
            }
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(64)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            // Terminals are spaced surface cards.
            section.interGroupSpacing = 8
            section.contentInsets = contentInsets
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(26)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    // MARK: - Data source

    private func buildDataSource() {
        let rowRegistration = UICollectionView.CellRegistration<HomeRowCell, Item> {
            [weak self] cell, indexPath, item in
            guard let self, let content = rowContents[item] else { return }
            cell.configure(content: content)
            let section = Section(rawValue: indexPath.section) ?? .terminals
            let area = section == .terminals ? "terminals" : "agents"
            cell.accessibilityIdentifier = "pedals.home.\(area).row.\(indexPath.item)"
        }
        let hintRegistration = UICollectionView.CellRegistration<HomeHintCell, Item> {
            cell, _, item in
            switch item {
            case .terminalsEmpty:
                cell.configure(
                    text: "No terminals. Create one from the + button.",
                    card: true
                )
                cell.accessibilityIdentifier = "pedals.home.terminals.empty"
            case .agentsEmpty:
                cell.configure(
                    text: "Agents you run on your Mac appear here. "
                        + "Install hooks from the Pedals menu bar app.",
                    card: false
                )
                cell.accessibilityIdentifier = "pedals.home.agents.empty"
            case .terminal, .agent:
                break
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<HomeSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            let section = Section(rawValue: indexPath.section)
            header.setTitle(section?.title ?? "")
            header.setHorizontalInset(section == .agents ? 16 : 0)
            header.onClear = section == .agents
                ? { [weak self] in self?.dismissSettledAgents() }
                : nil
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            switch item {
            case .terminal, .agent:
                collectionView.dequeueConfiguredReusableCell(
                    using: rowRegistration, for: indexPath, item: item
                )
            case .terminalsEmpty, .agentsEmpty:
                collectionView.dequeueConfiguredReusableCell(
                    using: hintRegistration, for: indexPath, item: item
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration, for: indexPath
            )
        }
    }

    // MARK: - Bindings

    private func bind() {
        // NOTE: @Published emits during willSet — render only from the emitted
        // values, never by reading the manager back inside the sink.
        manager.$terminals
            .combineLatest(manager.$agentRows, manager.$computers.map(\.count))
            .sink { [weak self] terminals, agentRows, computerCount in
                guard let self else { return }
                lastTerminals = terminals
                #if DEBUG
                lastAgentRows = Self.agentFixtureRows ?? agentRows
                #else
                lastAgentRows = agentRows
                #endif
                lastComputerCount = computerCount
                render()
            }
            .store(in: &cancellables)

        // Relative times ("5m") drift while nothing else changes.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    // MARK: - Rendering

    private func render() {
        let terminals = lastTerminals
        let agentRows = lastAgentRows
        let showHost = lastComputerCount > 1
        let now = Date()

        // Hard dedup rule: sessionId != nil AND a matching live terminal
        // exists → the agent renders inside that terminal row; otherwise it
        // is unmanaged and renders in the Agents section. Never both.
        let terminalIds = Set(terminals.map(\.id))
        let unmanaged = agentRows.filter { row in
            guard let sid = row.info.sessionId else { return true }
            return !terminalIds.contains(TerminalID(computerID: row.computerID, sid: sid))
        }

        var newContents: [Item: HomeRowContent] = [:]

        // Terminals section.
        struct SortableItem {
            let item: Item
            let rank: Int
            let time: Double
        }
        var terminalSortables: [SortableItem] = []
        for terminal in terminals {
            let item = Item.terminal(terminal.id)
            guard newContents[item] == nil else { continue }
            let agent = TerminalManager.agent(for: terminal.id, in: agentRows)
            newContents[item] = terminalRowContent(
                terminal: terminal, agent: agent, showHost: showHost, now: now
            )
            terminalSortables.append(SortableItem(
                item: item,
                rank: agent.map(\.state.attentionRank) ?? 4,
                time: agent?.updatedAt ?? terminal.info.createdAt
            ))
        }

        // Agents section (unmanaged only). Swipe-dismissed rows stay hidden
        // until the agent moves to a different state.
        let liveKeys = Set(unmanaged.map {
            AgentKey(computerID: $0.computerID, agentID: $0.info.id)
        })
        dismissedAgents = dismissedAgents.filter { liveKeys.contains($0.key) }
        lastUnmanaged = unmanaged
        var agentSortables: [SortableItem] = []
        for row in unmanaged {
            let key = AgentKey(computerID: row.computerID, agentID: row.info.id)
            guard dismissedAgents[key] != row.info.state else { continue }
            let item = Item.agent(key)
            guard newContents[item] == nil else { continue }
            newContents[item] = agentRowContent(row: row, showHost: showHost, now: now)
            agentSortables.append(SortableItem(
                item: item,
                rank: row.info.state.attentionRank,
                time: row.info.updatedAt
            ))
        }

        let sorter: (SortableItem, SortableItem) -> Bool = {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.time > $1.time
        }
        terminalSortables.sort(by: sorter)
        agentSortables.sort(by: sorter)

        let terminalItems = terminalSortables.isEmpty
            ? [Item.terminalsEmpty] : terminalSortables.map(\.item)
        let agentItems = agentSortables.isEmpty
            ? [Item.agentsEmpty] : agentSortables.map(\.item)

        let oldContents = rowContents
        rowContents = newContents

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.terminals, .agents])
        snapshot.appendItems(terminalItems, toSection: .terminals)
        snapshot.appendItems(agentItems, toSection: .agents)
        let survivors = Set(dataSource.snapshot().itemIdentifiers)
        let changed = snapshot.itemIdentifiers.filter {
            survivors.contains($0) && oldContents[$0] != newContents[$0]
        }
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func terminalRowContent(
        terminal: Terminal, agent: AgentInfo?, showHost: Bool, now: Date
    ) -> HomeRowContent {
        var chips: [String] = []
        let agentIcon = agent.flatMap { Self.agentAssetName($0.agent) }
        if let agent, agentIcon == nil {
            chips.append(Self.agentDisplayName(agent.agent))
        }
        if showHost {
            chips.append(terminal.computerName)
        }
        if let agent {
            let presentation = AgentActivity.Presentation(
                info: agent, fallbackSessionName: terminal.info.title
            )
            return HomeRowContent(
                indicator: .state(agent.state),
                icon: agentIcon,
                primary: presentation.title,
                secondary: presentation.detail,
                chips: chips,
                secondaryColor: HomeRowCell.stateColor(agent.state),
                time: CompactRelativeTime.string(from: agent.updatedAt, now: now),
                dimmed: false
            )
        }
        let dead = !terminal.info.alive || terminal.closing
        return HomeRowContent(
            indicator: dead ? .dead : .none,
            primary: terminal.info.title,
            secondary: Self.abbreviatePath(terminal.info.cwd),
            chips: chips,
            time: CompactRelativeTime.string(from: terminal.info.createdAt, now: now),
            dimmed: dead
        )
    }

    private func agentRowContent(
        row: AgentRow, showHost: Bool, now: Date
    ) -> HomeRowContent {
        let info = row.info
        let agentIcon = Self.agentAssetName(info.agent)
        // Deliberately spare: the mark identifies the agent (a name chip only
        // for unknown slugs from newer daemons), no terminal-app chip, host
        // chip only with multiple computers.
        var chips: [String] = agentIcon == nil ? [Self.agentDisplayName(info.agent)] : []
        if showHost {
            chips.append(row.computerName)
        }
        if !row.hostOnline {
            chips.append("offline")
        }
        let presentation = AgentActivity.Presentation(info: info)
        return HomeRowContent(
            indicator: .state(info.state),
            icon: agentIcon,
            primary: presentation.title,
            secondary: presentation.detail,
            chips: chips,
            secondaryColor: HomeRowCell.stateColor(info.state),
            time: row.hostOnline
                ? CompactRelativeTime.string(from: info.updatedAt, now: now)
                : nil,
            dimmed: !row.hostOnline,
            flat: true
        )
    }

    // MARK: - Agent dismissal

    private func agentSwipeConfiguration(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .agent(let key) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Dismiss") {
            [weak self] _, _, completion in
            // Re-resolve by key: the row list may have changed between the
            // swipe starting and the action firing.
            guard let self,
                  let row = lastUnmanaged.first(where: {
                      $0.computerID == key.computerID && $0.info.id == key.agentID
                  })
            else {
                completion(false)
                return
            }
            dismiss(row: row)
            completion(true)
        }
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    /// The Agents header's Clear action: dismisses every agent not
    /// currently working.
    private func dismissSettledAgents() {
        for row in lastUnmanaged where row.info.state != .running {
            dismiss(row: row)
        }
    }

    /// Optimistic dismissal: hide locally right away, then tell the daemon
    /// to drop the record (it reappears on the agent's next hook event).
    private func dismiss(row: AgentRow) {
        let key = AgentKey(computerID: row.computerID, agentID: row.info.id)
        dismissedAgents[key] = row.info.state
        manager.dismissAgent(computerID: row.computerID, agentID: row.info.id)
        render()
    }

    // MARK: - Text helpers

    static func agentOneLiner(_ agent: AgentInfo) -> String {
        AgentActivity.Presentation(info: agent).detail
    }

    static func agentDisplayName(_ slug: String) -> String {
        switch slug {
        case "claude": "Claude"
        case "codex": "Codex"
        case "copilot": "Copilot"
        case "grok": "Grok"
        case "hermes": "Hermes"
        case "kimi": "Kimi"
        case "kiro": "Kiro"
        case "omp": "Oh My Pi"
        case "opencode": "OpenCode"
        case "pi": "Pi"
        default: slug.capitalized
        }
    }

    /// Asset-catalog template mark for a known agent slug; nil falls back to
    /// the text chip so unknown agents from newer daemons stay labelled.
    static func agentAssetName(_ slug: String) -> String? {
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

    /// Home-relative path: `/Users/x/…` and `/home/x/…` become `~/…`. Remote
    /// home directories aren't known client-side, so this is a heuristic.
    static func abbreviatePath(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return path
    }

}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        if case .terminal = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(
        _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
    ) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .terminal(let id) = dataSource.itemIdentifier(for: indexPath) else { return }
        onSelectTerminal?(id)
    }
}

// MARK: - Row model

struct HomeRowContent: Equatable {
    enum Indicator: Equatable {
        /// Plain live tty: no mark.
        case none
        /// Agent state dot (color per state; orange/red are the only colors).
        case state(AgentState)
        /// Dead tty: the same red × the tab pills use.
        case dead
    }

    var indicator: Indicator
    /// Agent logo mark (template asset name), shown leading the text block.
    var icon: String?
    var primary: String
    var secondary: String
    var chips: [String]
    /// State tint for the secondary line; nil keeps the default gray.
    var secondaryColor: UIColor?
    /// Compact relative time; nil hides it (offline rows show a chip instead).
    var time: String?
    /// Offline computer or dead tty: whole row at reduced alpha.
    var dimmed: Bool
    /// Plain list row (no surface card background): the glanceable Agents
    /// section, visually distinct from the tappable terminal cards.
    var flat = false
}

/// "now", "5m", "2h", "3d".
enum CompactRelativeTime {
    static func string(from epochSeconds: Double, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - epochSeconds)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

// MARK: - Cells

/// One surface card row: indicator + primary over secondary on the left,
/// outline chips + relative time on the right.
// A list cell (not a plain cell) so the agents list section can attach
// native interactive swipe actions; the terminal section uses it unchanged.
private final class HomeRowCell: UICollectionViewListCell {
    private let iconView = UIImageView()
    /// Agent state badge on the icon's top-right corner. A canvas-colored
    /// ring keeps it readable over the mark; working blinks slowly.
    private let badgeView = UIView()
    private let primaryLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let chipsStack = UIStackView()
    private let timeLabel = UILabel()
    private var textLeadingToEdge: NSLayoutConstraint!
    private var textLeadingToIcon: NSLayoutConstraint!
    private var badgeBlinking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The list cell's default background configuration would repaint the
        // cell on highlight/selection; this cell drives contentView's color
        // itself for both the card and flat styles.
        backgroundConfiguration = .clear()
        contentView.backgroundColor = PedalsTheme.uiSurface
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous

        primaryLabel.font = PedalsTheme.uiEmphasizedTextFont
        primaryLabel.textColor = PedalsTheme.uiContent
        primaryLabel.numberOfLines = 1
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryLabel.font = .systemFont(ofSize: 13)
        secondaryLabel.textColor = PedalsTheme.uiSecondaryContent
        secondaryLabel.numberOfLines = 1
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [primaryLabel, secondaryLabel])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3

        chipsStack.axis = .horizontal
        chipsStack.alignment = .center
        chipsStack.spacing = 5

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = PedalsTheme.uiTertiaryContent
        timeLabel.textAlignment = .right

        let trailingStack = UIStackView(arrangedSubviews: [chipsStack, timeLabel])
        trailingStack.axis = .vertical
        trailingStack.alignment = .trailing
        trailingStack.spacing = 5
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = PedalsTheme.uiContent
        iconView.isHidden = true

        badgeView.layer.cornerRadius = 5
        badgeView.layer.borderWidth = 2
        badgeView.isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)
        contentView.addSubview(badgeView)
        contentView.addSubview(textStack)
        contentView.addSubview(trailingStack)
        textLeadingToEdge = textStack.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: 14
        )
        textLeadingToIcon = textStack.leadingAnchor.constraint(
            equalTo: iconView.trailingAnchor, constant: 10
        )
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            badgeView.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -1),
            badgeView.centerYAnchor.constraint(equalTo: iconView.topAnchor, constant: 1),
            badgeView.widthAnchor.constraint(equalToConstant: 10),
            badgeView.heightAnchor.constraint(equalToConstant: 10),
            textLeadingToEdge,
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            trailingStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -14
            ),
            trailingStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            trailingStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: textStack.trailingAnchor, constant: 10
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isFlat = false

    override var isHighlighted: Bool {
        didSet {
            guard !isFlat else { return }
            contentView.backgroundColor = isHighlighted
                ? PedalsTheme.uiSelection : PedalsTheme.uiSurface
        }
    }

    func configure(content: HomeRowContent) {
        isFlat = content.flat
        contentView.backgroundColor = content.flat ? .clear : PedalsTheme.uiSurface
        let icon = content.icon.flatMap { UIImage(named: $0) }
        iconView.image = icon
        iconView.isHidden = icon == nil
        // The badge ring must match whatever the dot sits on: the card
        // surface for terminal rows, the bare canvas for flat agent rows.
        badgeView.layer.borderColor = (content.flat
            ? PedalsTheme.uiCanvas
            : UIColor(white: 0.075, alpha: 1)).cgColor
        configureBadge(for: content, hasIcon: icon != nil)
        // Deactivate before activating the other: both live for a beat
        // otherwise, and UIKit logs an unsatisfiable-constraints break.
        textLeadingToEdge.isActive = false
        textLeadingToIcon.isActive = false
        (icon == nil ? textLeadingToEdge : textLeadingToIcon)?.isActive = true

        primaryLabel.attributedText = Self.primaryText(
            content: content, inlineIndicator: icon == nil
        )
        secondaryLabel.text = content.secondary
        secondaryLabel.textColor = content.secondaryColor ?? PedalsTheme.uiSecondaryContent
        secondaryLabel.isHidden = content.secondary.isEmpty

        // Reuse chip views: recreating them while the cell is being
        // reconfigured in place leaves the fresh labels collapsed until the
        // next full layout pass.
        while chipsStack.arrangedSubviews.count > content.chips.count {
            chipsStack.arrangedSubviews.last?.removeFromSuperview()
        }
        while chipsStack.arrangedSubviews.count < content.chips.count {
            chipsStack.addArrangedSubview(HomeChipView(text: ""))
        }
        for (chip, view) in zip(content.chips, chipsStack.arrangedSubviews) {
            (view as? HomeChipView)?.text = chip
        }
        chipsStack.isHidden = content.chips.isEmpty

        timeLabel.text = content.time
        timeLabel.isHidden = content.time == nil

        contentView.alpha = content.dimmed ? 0.45 : 1
    }

    /// The corner badge: state color, with working as a slow white blink.
    /// Finished shows no badge at all — a settled agent needs no marker.
    private func configureBadge(for content: HomeRowContent, hasIcon: Bool) {
        guard hasIcon, case .state(let state) = content.indicator, state != .done else {
            badgeView.isHidden = true
            setBadgeBlinking(false)
            return
        }
        badgeView.isHidden = false
        badgeView.backgroundColor = Self.stateColor(state)
        setBadgeBlinking(state == .running)
    }

    private func setBadgeBlinking(_ blinking: Bool) {
        guard blinking != badgeBlinking else {
            if blinking { startBlinkAnimation() } // re-add after window moves
            return
        }
        badgeBlinking = blinking
        if blinking {
            startBlinkAnimation()
        } else {
            badgeView.layer.removeAnimation(forKey: "pedals.blink")
        }
    }

    private func startBlinkAnimation() {
        guard badgeBlinking,
              badgeView.layer.animation(forKey: "pedals.blink") == nil
        else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.25
        blink.duration = 0.9
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        badgeView.layer.add(blink, forKey: "pedals.blink")
    }

    /// Core Animation drops animations when the cell leaves the window
    /// (scrolling, backgrounding); restore the blink on re-entry.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startBlinkAnimation() }
    }

    /// One state, one color: working white, blocked orange, error red,
    /// finished green.
    static func stateColor(_ state: AgentState) -> UIColor {
        switch state {
        case .waiting: PedalsTheme.uiWarning
        case .error: PedalsTheme.uiCritical
        case .running: PedalsTheme.uiContent
        case .done: PedalsTheme.uiSuccess
        }
    }

    private static func primaryText(
        content: HomeRowContent, inlineIndicator: Bool
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let markFont = UIFont.systemFont(ofSize: 12, weight: .bold)
        switch content.indicator {
        case .none:
            break
        case .state(let state) where inlineIndicator && state != .done:
            let color = stateColor(state)
            text.append(NSAttributedString(
                string: "● ",
                attributes: [.foregroundColor: color, .font: markFont]
            ))
        case .state:
            break
        case .dead:
            text.append(NSAttributedString(
                string: "× ",
                attributes: [.foregroundColor: PedalsTheme.uiCritical, .font: markFont]
            ))
        }
        text.append(NSAttributedString(
            string: content.primary,
            attributes: [
                .foregroundColor: content.indicator == .dead
                    ? PedalsTheme.uiSecondaryContent : PedalsTheme.uiContent,
                .font: PedalsTheme.uiEmphasizedTextFont,
            ]
        ))
        return text
    }
}

/// Empty-state hint: either a row-styled surface card or bare secondary text.
private final class HomeHintCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 13)
        label.textColor = PedalsTheme.uiSecondaryContent
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String, card: Bool) {
        label.text = text
        contentView.backgroundColor = card ? PedalsTheme.uiSurface : .clear
    }
}

private final class HomeSectionHeaderView: UICollectionReusableView {
    private let label = UILabel()
    private let clearButton = UIButton(type: .system)
    private var labelLeadingConstraint: NSLayoutConstraint!
    private var clearTrailingConstraint: NSLayoutConstraint!

    /// Non-nil shows the trailing Clear control (the Agents section).
    var onClear: (() -> Void)? {
        didSet { clearButton.isHidden = onClear == nil }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = PedalsTheme.uiSecondaryContent
        label.translatesAutoresizingMaskIntoConstraints = false

        clearButton.setTitle("Clear", for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 11)
        clearButton.setTitleColor(PedalsTheme.uiTertiaryContent, for: .normal)
        clearButton.accessibilityIdentifier = "pedals.home.agents.clear"
        clearButton.isHidden = true
        clearButton.addAction(
            UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside
        )
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(clearButton)
        labelLeadingConstraint = label.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: 4
        )
        clearTrailingConstraint = clearButton.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -4
        )
        NSLayoutConstraint.activate([
            labelLeadingConstraint,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            clearTrailingConstraint,
            clearButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) {
        label.text = title
    }

    func setHorizontalInset(_ inset: CGFloat) {
        labelLeadingConstraint.constant = inset + 4
        clearTrailingConstraint.constant = -(inset + 4)
    }
}

/// Thin 1px outline capsule chip ("hostname", "Claude", "iTerm2", "offline").
private final class HomeChipView: UIView {
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    init(text: String) {
        super.init(frame: .zero)
        layer.borderWidth = 1
        layer.borderColor = PedalsTheme.uiSeparator.cgColor

        label.text = text
        label.font = .systemFont(ofSize: 11)
        label.textColor = PedalsTheme.uiSecondaryContent
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
    }
}
