import TTYBuildKit
import UIKit

/// Safari-style top tab strip: one pill per session, the active pill expanded
/// with icon/title/close, inactive pills collapsed to icons. Widths follow
/// Chrome's squeeze model (inactive tabs compress before the strip scrolls),
/// and `setSwitchProgress` lets a content-area pan drive the expand/collapse
/// interpolation so the strip follows the finger.
final class TabStripView: UIView {
    struct Tab: Equatable {
        let id: TerminalID
        var title: String
        var alive: Bool
        /// A managed coding agent occupying this terminal. Nil uses the
        /// standard terminal symbol.
        var agent: String?
        var agentState: AgentState?
    }

    var onSelect: ((TerminalID) -> Void)?
    var onClose: ((TerminalID) -> Void)?
    var onHome: (() -> Void)?
    var onCreate: (() -> Void)?

    static let height: CGFloat = 44
    private static let pillHeight: CGFloat = 40
    private static let spacing: CGFloat = 8
    private static let maxActiveWidth: CGFloat = 230
    private static let minActiveWidth: CGFloat = 150
    private static let maxInactiveWidth: CGFloat = 64
    private static let minInactiveWidth: CGFloat = 40

    private let scrollView = UIScrollView()
    /// App title shown in the strip's empty middle while no tabs exist.
    private let titleLabel = UILabel()
    private let plusButton = UIButton(type: .system)
    private let plusGlass = GlassView()
    private let homeButton = UIButton(type: .system)
    private let homeGlass = GlassView()

    private(set) var tabs: [Tab] = []
    private var activeIndex: Int?
    /// Remembered across trips to Home (activeIndex == nil): the pill that was
    /// focused last keeps its expanded width there, restyled as inactive.
    private var lastActiveId: TerminalID?
    private var pills: [TerminalID: TabPillView] = [:]

    /// Non-nil while a pan drives the strip: (fromIndex, toIndex, progress).
    private var transition: (from: Int, to: Int, progress: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.text = "TTY.Build"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = TTYBuildTheme.uiContent
        titleLabel.textAlignment = .center
        titleLabel.isHidden = true
        addSubview(titleLabel)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // Scrolled pills must not bleed over the fixed settings/plus pills.
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        plusGlass.contentView.addSubview(plusButton)
        plusButton.setImage(
            UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            ),
            for: .normal
        )
        plusButton.tintColor = .label
        plusButton.addAction(UIAction { [weak self] _ in self?.onCreate?() }, for: .touchUpInside)
        addSubview(plusGlass)

        // Home lives as a permanent, un-closeable leftmost tab; the settings
        // gear moved onto the Home page itself.
        homeGlass.contentView.addSubview(homeButton)
        homeButton.setImage(
            UIImage(
                systemName: "house",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            ),
            for: .normal
        )
        homeButton.tintColor = .secondaryLabel
        homeButton.accessibilityIdentifier = "ttybuild.home.tab"
        homeButton.accessibilityLabel = "Home"
        homeButton.addAction(
            UIAction { [weak self] _ in self?.onHome?() }, for: .touchUpInside
        )
        addSubview(homeGlass)
    }

    /// Renders the fixed home pill selected (Home page visible) or not.
    func setHomeSelected(_ selected: Bool) {
        homeButton.tintColor = selected ? .label : .secondaryLabel
        homeGlass.contentView.backgroundColor = selected ? TTYBuildTheme.uiSelection : .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Model

    /// When non-nil, tapping + presents this menu (multi-computer choose-target);
    /// when nil, tapping + fires `onCreate` directly (single computer).
    func setCreateMenu(_ menu: UIMenu?) {
        plusButton.menu = menu
        plusButton.showsMenuAsPrimaryAction = menu != nil
    }

    func update(tabs newTabs: [Tab], activeId: TerminalID?) {
        let oldActive = activeIndex
        tabs = newTabs
        activeIndex = activeId.flatMap { id in tabs.firstIndex { $0.id == id } }
        if activeIndex != nil { lastActiveId = activeId }

        var seen = Set<TerminalID>()
        for tab in tabs {
            seen.insert(tab.id)
            if let pill = pills[tab.id] {
                pill.configure(tab: tab)
            } else {
                let pill = TabPillView()
                pill.configure(tab: tab)
                pill.onTap = { [weak self] in self?.onSelect?(tab.id) }
                pill.onClose = { [weak self] in self?.onClose?(tab.id) }
                pills[tab.id] = pill
                scrollView.addSubview(pill)
            }
        }
        for (id, pill) in pills where !seen.contains(id) {
            pills.removeValue(forKey: id)
            pill.removeFromSuperview()
        }

        // The strip's empty middle carries the app title until the first tab.
        titleLabel.isHidden = !tabs.isEmpty

        transition = nil
        let animated = oldActive != activeIndex && window != nil
        if animated {
            UIView.animate(
                withDuration: 0.45, delay: 0,
                usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
                options: [.allowUserInteraction]
            ) {
                self.layoutStrip()
            }
        } else {
            setNeedsLayout()
        }
    }

    // MARK: - Gesture-driven transition

    func setSwitchProgress(from: Int, to: Int, progress: CGFloat) {
        guard from != to, tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        transition = (from, to, max(0, min(1, progress)))
        layoutStrip()
    }

    func cancelSwitchProgress() {
        guard transition != nil else { return }
        transition = nil
        UIView.animate(
            withDuration: 0.4, delay: 0,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
            options: [.allowUserInteraction]
        ) {
            self.layoutStrip()
        }
    }

    /// Commit an in-flight gesture transition to `targetIndex`, settling the
    /// pills to the target layout in one animation meant to run alongside the
    /// content page animation (pass its spring params) — instead of freezing at
    /// the release progress and snapping only after the page settles. The model
    /// `update(tabs:activeId:)` that follows sees activeIndex already at target
    /// and re-animates nothing.
    func commitSwitch(
        to targetIndex: Int,
        duration: TimeInterval, damping: CGFloat, initialVelocity: CGFloat
    ) {
        guard tabs.indices.contains(targetIndex) else { return }
        transition = nil
        activeIndex = targetIndex
        lastActiveId = tabs[targetIndex].id
        UIView.animate(
            withDuration: duration, delay: 0,
            usingSpringWithDamping: damping, initialSpringVelocity: initialVelocity,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.layoutStrip()
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let pillSize: CGFloat = Self.pillHeight
        homeGlass.frame = CGRect(
            x: 12,
            y: (bounds.height - pillSize) / 2,
            width: pillSize,
            height: pillSize
        )
        homeButton.frame = homeGlass.contentView.bounds

        plusGlass.frame = CGRect(
            x: bounds.width - pillSize - 12,
            y: (bounds.height - pillSize) / 2,
            width: pillSize,
            height: pillSize
        )
        plusButton.frame = plusGlass.contentView.bounds

        scrollView.frame = CGRect(
            x: homeGlass.frame.maxX + Self.spacing, y: 0,
            width: plusGlass.frame.minX - homeGlass.frame.maxX - Self.spacing * 2,
            height: bounds.height
        )
        titleLabel.frame = scrollView.frame
        layoutStrip()
    }

    /// Width for each tab index under the squeeze model, honoring an in-flight
    /// gesture transition by interpolating active widths.
    private func widths(available: CGFloat) -> [CGFloat] {
        guard !tabs.isEmpty else { return [] }
        let count = CGFloat(tabs.count)
        let spacingTotal = Self.spacing * (count - 1)

        // A lone tab claims the whole strip.
        guard tabs.count > 1 else { return [available] }

        let rememberedIndex = lastActiveId.flatMap { id in
            tabs.firstIndex { $0.id == id }
        }
        let expandedIndex = activeIndex ?? rememberedIndex

        // On Home before any terminal has been focused, two tabs otherwise
        // have no expansion owner and sit as two tiny icons beside a large
        // hole. Keep the first one collapsed and let the final tab absorb the
        // entire remainder (including wide landscape layouts).
        if tabs.count == 2, expandedIndex == nil {
            let inactive = min(
                Self.maxInactiveWidth,
                max(Self.minInactiveWidth, available - Self.spacing - Self.minActiveWidth)
            )
            let expanded = max(
                Self.minActiveWidth,
                available - Self.spacing - inactive
            )
            return [inactive, expanded]
        }

        var active = Self.maxActiveWidth
        var inactive = (available - spacingTotal - active) / (count - 1)
        if inactive < Self.maxInactiveWidth {
            // Squeeze: shrink inactive first, then the active pill, then scroll.
            inactive = max(Self.minInactiveWidth, inactive)
            let remaining = available - spacingTotal - inactive * (count - 1)
            active = max(Self.minActiveWidth, min(Self.maxActiveWidth, remaining))
        } else {
            inactive = min(Self.maxInactiveWidth, inactive)
        }

        // No active tab (Home page visible): the last-focused pill keeps its
        // expanded width (restyled inactive by layoutStrip); the rest collapse.
        return tabs.indices.map { index in
            var expansion: CGFloat = index == expandedIndex ? 1 : 0
            if let transition {
                if index == transition.from { expansion = 1 - transition.progress }
                if index == transition.to { expansion = transition.progress }
            }
            return inactive + (active - inactive) * expansion
        }
    }

    private func layoutStrip() {
        let widths = widths(available: scrollView.bounds.width)
        // Mid-drag the title's active styling hands over at the halfway point
        // rather than only on commit.
        let styleActive = transition.map { $0.progress >= 0.5 ? $0.to : $0.from }
            ?? activeIndex
        var x: CGFloat = 0
        for (index, tab) in tabs.enumerated() {
            guard let pill = pills[tab.id] else { continue }
            let width = widths[index]
            pill.frame = CGRect(
                x: x,
                y: (bounds.height - Self.pillHeight) / 2,
                width: width,
                height: Self.pillHeight
            )
            let expansion = expansionAmount(index: index, width: width)
            pill.setExpansion(expansion, isActive: index == styleActive)
            x += width + Self.spacing
        }
        let contentWidth = max(0, x - Self.spacing)
        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        scrollToActive()
    }

    private func expansionAmount(index: Int, width: CGFloat) -> CGFloat {
        let range = Self.minActiveWidth - Self.maxInactiveWidth
        return max(0, min(1, (width - Self.maxInactiveWidth) / range))
    }

    private func scrollToActive() {
        guard let activeIndex, let pill = pills[tabs[activeIndex].id],
              scrollView.contentSize.width > scrollView.bounds.width
        else { return }
        let target = pill.frame.insetBy(dx: -Self.spacing * 3, dy: 0)
        scrollView.scrollRectToVisible(target, animated: false)
    }
}

/// One tab pill. Expanded (active) it shows icon · title · close; collapsed it
/// keeps the icon centered. A managed agent replaces the terminal symbol and
/// carries the same state badge used on Home.
final class TabPillView: UIView {
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?

    private let glass = GlassView()
    private let iconView = UIImageView()
    private let badgeView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.accessibilityIdentifier = "ttybuild.tab.icon"
        glass.contentView.addSubview(iconView)

        badgeView.layer.cornerRadius = 4
        badgeView.layer.borderWidth = 1.5
        badgeView.layer.borderColor = TTYBuildTheme.uiCanvas.cgColor
        badgeView.isHidden = true
        badgeView.accessibilityIdentifier = "ttybuild.tab.agent-state-badge"
        glass.contentView.addSubview(badgeView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(titleLabel)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: symbolConfig), for: .normal
        )
        closeButton.tintColor = .secondaryLabel
        closeButton.addAction(
            UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside
        )
        glass.contentView.addSubview(closeButton)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var alive = true
    private var isActive = false
    private var expansion: CGFloat = 0
    private var badgeBlinking = false

    func configure(tab: TabStripView.Tab) {
        titleLabel.text = tab.title
        if let agent = tab.agent {
            if let asset = HomeViewController.agentAssetName(agent),
               let image = UIImage(named: asset)
            {
                iconView.image = image.withRenderingMode(.alwaysTemplate)
            } else {
                iconView.image = UIImage(systemName: "sparkles")
            }
        } else {
            iconView.image = UIImage(
                systemName: "terminal",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            )
        }
        configureBadge(state: tab.agent == nil ? nil : tab.agentState)
        alive = tab.alive
        accessibilityLabel = tab.title
        applyTitleStyle()
    }

    /// 0 = collapsed icon pill, 1 = fully expanded active pill.
    func setExpansion(_ amount: CGFloat, isActive: Bool) {
        expansion = amount
        self.isActive = isActive
        titleLabel.alpha = amount
        closeButton.alpha = amount
        // An expanded pill's × always works — an expanded pill remains while
        // Home is the visible page (no active tab).
        closeButton.isUserInteractionEnabled = amount > 0.5
        applyTitleStyle()
        setNeedsLayout()
    }

    /// Expanded-but-inactive (Home visible) reads as unfocused: the title
    /// dims to the secondary color instead of the active label color.
    private func applyTitleStyle() {
        titleLabel.textColor = alive && isActive ? .label : .secondaryLabel
        iconView.tintColor = alive
            ? (isActive ? .label : .secondaryLabel)
            : TTYBuildTheme.uiCritical
    }

    /// Home hides the badge for a completed agent; the tab follows the same
    /// rule. Running blinks, while waiting/error remain steady semantic dots.
    private func configureBadge(state: AgentState?) {
        guard let state, state != .done else {
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
            if blinking { startBlinkAnimation() }
            return
        }
        badgeBlinking = blinking
        if blinking {
            startBlinkAnimation()
        } else {
            badgeView.layer.removeAnimation(forKey: "ttybuild.tab.badge.blink")
        }
    }

    private func startBlinkAnimation() {
        guard badgeBlinking,
              badgeView.layer.animation(forKey: "ttybuild.tab.badge.blink") == nil
        else { return }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.25
        blink.duration = 0.9
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        badgeView.layer.add(blink, forKey: "ttybuild.tab.badge.blink")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startBlinkAnimation() }
    }

    private static func stateColor(_ state: AgentState) -> UIColor {
        switch state {
        case .waiting: TTYBuildTheme.uiWarning
        case .error: TTYBuildTheme.uiCritical
        case .running: TTYBuildTheme.uiContent
        case .done: TTYBuildTheme.uiSuccess
        }
    }

    @objc private func didTap() {
        onTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = glass.contentView.bounds
        let iconSize: CGFloat = 18
        let collapsedX = (bounds.width - iconSize) / 2
        let expandedX: CGFloat = 14
        let iconX = collapsedX + (expandedX - collapsedX) * expansion
        iconView.frame = CGRect(
            x: iconX,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        let badgeSize: CGFloat = 8
        badgeView.frame = CGRect(
            x: iconView.frame.maxX - badgeSize / 2 + 1,
            y: iconView.frame.minY - badgeSize / 2 + 1,
            width: badgeSize,
            height: badgeSize
        )

        let side: CGFloat = 30
        closeButton.frame = CGRect(
            x: bounds.width - side - 6, y: (bounds.height - side) / 2, width: side, height: side
        )
        let titleX = iconView.frame.maxX + 9
        titleLabel.frame = CGRect(
            x: titleX,
            y: 0,
            width: max(0, closeButton.frame.minX - titleX - 2),
            height: bounds.height
        )
    }
}
