import UIKit

/// A two-page terminal keyboard shown in place of the system keyboard.
///
/// The first page contains terminal/navigation keys; swiping left reveals a
/// complete US QWERTY surface. A fixed footer keeps Shift, Control, Option,
/// and Command reachable on both pages. The modifiers are owned by the
/// active TerminalHost and their white outline remains visible until the next
/// non-modifier key consumes the chord.
final class TerminalKeyboardView: UIInputView, UIInputViewAudioFeedback,
    UIScrollViewDelegate
{
    var onKey: ((TerminalInputKey) -> Void)?
    var onModifierToggle: ((TerminalModifier) -> Void)?

    private enum Page: Int {
        case terminal = 0
        case qwerty = 1
    }

    private static let preferredHeight: CGFloat = 346
    private static let pageSpacing: CGFloat = 12
    private let glass = GlassView()
    private let pageContainer = UIScrollView()
    private let pagePanGesture = UIPanGestureRecognizer()
    private let fixedFooter = UIStackView()
    private let terminalPage = UIView()
    private let pageSpacer = UIView()
    private let qwertyPage = UIView()
    private let pageControl = UIPageControl()
    private var currentPage: Page = .terminal
    private var lastPageWidth: CGFloat = 0
    private var hasPositionedInitialPage = false
    private var shouldPlayPagingHintWhenAttached = false
    private var isPlayingPagingHint = false
    private var panStartOffset: CGFloat = 0
    private var modifierButtons: [TerminalModifier: [TerminalKeyboardButton]] = [:]
    private var characterButtons: [(button: TerminalKeyboardButton, key: String)] = []
    private var modifierState = TerminalModifierState()

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.preferredHeight),
            inputViewStyle: .keyboard
        )

        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = TTYBuildTheme.uiCanvas
        accessibilityIdentifier = "terminal-expanded-keyboard"

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 22
        addSubview(glass)

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.clipsToBounds = true
        pageContainer.isPagingEnabled = true
        pageContainer.showsHorizontalScrollIndicator = false
        pageContainer.showsVerticalScrollIndicator = false
        pageContainer.alwaysBounceVertical = false
        pageContainer.bounces = false
        pageContainer.isDirectionalLockEnabled = true
        pageContainer.decelerationRate = .fast
        pageContainer.delaysContentTouches = false
        pageContainer.canCancelContentTouches = true
        pageContainer.contentInsetAdjustmentBehavior = .never
        // Keyboard input views live in a separate system window where an
        // embedded scroll view's own pan recognizer is not consistently
        // handed touch drags. Drive the same content offset with our own pan
        // so movement stays under the finger and always snaps to a full page.
        pageContainer.isScrollEnabled = false
        pageContainer.delegate = self
        pageContainer.accessibilityIdentifier = "terminal-keyboard-page-container"
        glass.contentView.addSubview(pageContainer)

        pagePanGesture.addTarget(self, action: #selector(handlePagePan(_:)))
        pagePanGesture.minimumNumberOfTouches = 1
        pagePanGesture.maximumNumberOfTouches = 1
        pagePanGesture.cancelsTouchesInView = true
        pagePanGesture.delaysTouchesBegan = false
        pagePanGesture.name = "terminal-keyboard-page-pan"
        pageContainer.addGestureRecognizer(pagePanGesture)

        fixedFooter.translatesAutoresizingMaskIntoConstraints = false
        fixedFooter.axis = .horizontal
        fixedFooter.alignment = .fill
        fixedFooter.distribution = .fill
        fixedFooter.spacing = 5
        fixedFooter.accessibilityIdentifier = "terminal-keyboard-fixed-footer"
        glass.contentView.addSubview(fixedFooter)

        for page in [terminalPage, pageSpacer, qwertyPage] {
            page.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview(page)
        }
        NSLayoutConstraint.activate([
            terminalPage.leadingAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.leadingAnchor
            ),
            terminalPage.topAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.topAnchor
            ),
            terminalPage.bottomAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.bottomAnchor
            ),
            terminalPage.widthAnchor.constraint(
                equalTo: pageContainer.frameLayoutGuide.widthAnchor
            ),
            terminalPage.heightAnchor.constraint(
                equalTo: pageContainer.frameLayoutGuide.heightAnchor
            ),
            pageSpacer.leadingAnchor.constraint(equalTo: terminalPage.trailingAnchor),
            pageSpacer.topAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.topAnchor
            ),
            pageSpacer.bottomAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.bottomAnchor
            ),
            pageSpacer.widthAnchor.constraint(equalToConstant: Self.pageSpacing),

            qwertyPage.leadingAnchor.constraint(equalTo: pageSpacer.trailingAnchor),
            qwertyPage.trailingAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.trailingAnchor
            ),
            qwertyPage.topAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.topAnchor
            ),
            qwertyPage.bottomAnchor.constraint(
                equalTo: pageContainer.contentLayoutGuide.bottomAnchor
            ),
            qwertyPage.widthAnchor.constraint(equalTo: pageContainer.frameLayoutGuide.widthAnchor),
            qwertyPage.heightAnchor.constraint(equalTo: pageContainer.frameLayoutGuide.heightAnchor),
        ])

        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.numberOfPages = 2
        pageControl.currentPage = Page.terminal.rawValue
        pageControl.currentPageIndicatorTintColor = TTYBuildTheme.uiContent.withAlphaComponent(0.9)
        pageControl.pageIndicatorTintColor = TTYBuildTheme.uiContent.withAlphaComponent(0.24)
        pageControl.backgroundStyle = .minimal
        pageControl.allowsContinuousInteraction = false
        pageControl.accessibilityLabel = "Keyboard page"
        pageControl.accessibilityIdentifier = "terminal-keyboard-page-control"
        pageControl.addAction(
            UIAction { [weak self] _ in self?.selectPageFromControl() },
            for: .valueChanged
        )
        glass.contentView.addSubview(pageControl)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.preferredHeight),

            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            pageContainer.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            pageContainer.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            pageContainer.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
            pageContainer.bottomAnchor.constraint(equalTo: pageControl.topAnchor, constant: -2),

            pageControl.centerXAnchor.constraint(equalTo: glass.contentView.centerXAnchor),
            pageControl.bottomAnchor.constraint(equalTo: fixedFooter.topAnchor, constant: -2),
            pageControl.heightAnchor.constraint(equalToConstant: 16),

            fixedFooter.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            fixedFooter.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            fixedFooter.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
            fixedFooter.heightAnchor.constraint(equalToConstant: 40),
        ])

        buildTerminalPage()
        buildQWERTYPage()
        buildFixedFooter()
        updatePageControl()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionCurrentPageIfNeeded(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            cancelPagingHint(settleOnCurrentPage: true)
            hasPositionedInitialPage = false
            return
        }

        // UIInputView may reset an embedded scroll view's offset while it is
        // being attached to the remote keyboard window. Re-apply the logical
        // page on the next main-loop turn, after that attachment finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.positionCurrentPageIfNeeded(force: true)
            self.playPagingHintIfNeeded()
        }
    }

    /// Starts a fresh expanded-keyboard presentation. This is deliberately
    /// called by the toolbar mode toggle rather than inferred from
    /// `didMoveToWindow`: UIKit can temporarily detach and reattach an
    /// `UIInputView` while it remains open, and that must not reset a user's
    /// in-progress page or replay the hint.
    func prepareForPresentation(showPagingHint: Bool) {
        cancelPagingHint(settleOnCurrentPage: false)
        currentPage = .terminal
        updatePageControl()
        hasPositionedInitialPage = false
        shouldPlayPagingHintWhenAttached = showPagingHint
        positionCurrentPageIfNeeded(force: true)
    }

    private func positionCurrentPageIfNeeded(force: Bool) {
        let width = pageContainer.bounds.width
        pageContainer.layoutIfNeeded()
        guard
            width > 0,
            pageContainer.contentSize.width >= width * 1.9,
            force || !hasPositionedInitialPage || abs(width - lastPageWidth) > 0.5
        else { return }
        lastPageWidth = width
        hasPositionedInitialPage = false
        pageContainer.setContentOffset(
            CGPoint(x: currentPage == .terminal ? 0 : width, y: 0),
            animated: false
        )
        hasPositionedInitialPage = true
    }

    func setModifierState(_ state: TerminalModifierState) {
        modifierState = state
        for modifier in TerminalModifier.allCases {
            let selected = state.isActive(modifier)
            modifierButtons[modifier]?.forEach { $0.isSelected = selected }
        }
        updateCharacterLabels()
    }

    /// Internal for deterministic UI tests; user interaction calls the same
    /// transition through the page control or a horizontal page swipe.
    func showQWERTYPage(animated: Bool = true) {
        setPage(.qwerty, animated: animated)
    }

    func showTerminalPage(animated: Bool = true) {
        setPage(.terminal, animated: animated)
    }

    private func buildTerminalPage() {
        buildRows([
            [
                .text("esc", .escape, "Escape"),
                .text("F1", .function(1), "F1"),
                .text("F2", .function(2), "F2"),
                .text("F3", .function(3), "F3"),
                .text("F4", .function(4), "F4"),
                .text("F5", .function(5), "F5"),
                .text("F6", .function(6), "F6"),
            ],
            [
                .text("F7", .function(7), "F7"),
                .text("F8", .function(8), "F8"),
                .text("F9", .function(9), "F9"),
                .text("F10", .function(10), "F10"),
                .text("F11", .function(11), "F11"),
                .text("F12", .function(12), "F12"),
                .text("clear", .clearScreen, "Clear Screen", width: 1.25),
            ],
            [
                .text("home", .home, "Home"),
                .text("pg↑", .pageUp, "Page Up"),
                .symbol("arrow.up", .arrow(.up), "Up"),
                .text("pg↓", .pageDown, "Page Down"),
                .text("end", .end, "End"),
            ],
            [
                .symbol("arrow.left", .arrow(.left), "Left"),
                .symbol("arrow.down", .arrow(.down), "Down"),
                .symbol("arrow.right", .arrow(.right), "Right"),
                .text("ins", .insert, "Insert"),
                .text("del", .deleteForward, "Forward Delete"),
            ],
            [
                .text("tab", .tab, "Tab", width: 1.1),
                .symbol("delete.left", .backspace, "Backspace", width: 1.1),
                .symbol("return.left", .enter, "Return", width: 1.2),
            ],
        ], in: terminalPage)
    }

    private func buildQWERTYPage() {
        buildRows([
            "1234567890".map { .character(String($0)) },
            "qwertyuiop".map { .character(String($0)) },
            "asdfghjkl".map { .character(String($0)) },
            [
                .character("z"), .character("x"), .character("c"),
                .character("v"), .character("b"), .character("n"), .character("m"),
                .symbol("delete.left", .backspace, "Backspace", width: 1.35),
            ],
            ["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/"]
                .map { .character($0) },
            [
                .text("esc", .escape, "Escape", width: 1.2),
                .text("tab", .tab, "Tab", width: 1.2),
                .text("space", .text(" "), "Space", width: 5),
                .symbol("return.left", .enter, "Return", width: 1.5),
            ],
        ], in: qwertyPage)
    }

    private func buildFixedFooter() {
        let descriptions: [KeyDescription] = [
            .modifier("⇧", .shift, "Shift", width: 1.1),
            .modifier("⌃", .ctrl, "Control"),
            .modifier("⌥", .alt, "Option"),
            .modifier("⌘", .command, "Command"),
        ]
        addButtons(descriptions, to: fixedFooter)
    }

    private func buildRows(
        _ descriptions: [[KeyDescription]],
        in page: UIView,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0
    ) {
        let rows = UIStackView()
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.alignment = .fill
        rows.distribution = .fillEqually
        rows.spacing = 5
        page.addSubview(rows)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: leadingInset),
            rows.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -trailingInset),
            rows.topAnchor.constraint(equalTo: page.topAnchor),
            rows.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])

        for descriptions in descriptions {
            addRow(descriptions, to: rows)
        }
    }

    private func addRow(_ descriptions: [KeyDescription], to rows: UIStackView) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fill
        row.spacing = 5

        addButtons(descriptions, to: row)
        rows.addArrangedSubview(row)
    }

    private func addButtons(_ descriptions: [KeyDescription], to row: UIStackView) {
        var weightedButtons: [(TerminalKeyboardButton, CGFloat)] = []
        for description in descriptions {
            let button = makeButton(for: description)
            row.addArrangedSubview(button)
            weightedButtons.append((button, description.width))
        }

        if let (reference, referenceWidth) = weightedButtons.first {
            for (button, width) in weightedButtons.dropFirst() {
                button.widthAnchor.constraint(
                    equalTo: reference.widthAnchor,
                    multiplier: width / referenceWidth
                ).isActive = true
            }
        }
    }

    private func makeButton(for description: KeyDescription) -> TerminalKeyboardButton {
        let button = TerminalKeyboardButton()
        button.accessibilityLabel = description.accessibilityLabel
        button.accessibilityIdentifier = description.identifier

        switch description.content {
        case .title(let title):
            configureTitle(title, on: button)
        case .character(let key):
            configureTitle(key, on: button)
            characterButtons.append((button, key))
        case .symbol(let symbol):
            button.setImage(
                UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: 13, weight: .semibold
                    )
                ),
                for: .normal
            )
        }

        switch description.action {
        case .key(let key):
            button.addAction(
                UIAction { [weak self] _ in
                    UIDevice.current.playInputClick()
                    self?.onKey?(key)
                },
                for: .touchUpInside
            )
        case .modifier(let modifier):
            modifierButtons[modifier, default: []].append(button)
            button.addAction(
                UIAction { [weak self] _ in
                    UIDevice.current.playInputClick()
                    self?.onModifierToggle?(modifier)
                },
                for: .touchUpInside
            )
        }

        return button
    }

    private func configureTitle(_ title: String, on button: UIButton) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.62
    }

    private func updateCharacterLabels() {
        for (button, key) in characterButtons {
            let title = modifierState.shift
                ? TerminalKeyboardText.applyingShift(to: key)
                : key
            button.setTitle(title, for: .normal)
        }
    }

    private func selectPageFromControl() {
        let page = Page(rawValue: pageControl.currentPage) ?? .terminal
        setPage(page, animated: true)
    }

    private func setPage(_ page: Page, animated: Bool) {
        currentPage = page
        updatePageControl()
        let target = CGPoint(x: page == .terminal ? 0 : pageTravelDistance, y: 0)
        guard animated else {
            pageContainer.setContentOffset(target, animated: false)
            return
        }

        UIView.animate(
            withDuration: 0.32,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.25,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.pageContainer.contentOffset = target
        }
    }

    private var pageTravelDistance: CGFloat {
        max(pageContainer.bounds.width + Self.pageSpacing, 1)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard
            scrollView === pageContainer,
            hasPositionedInitialPage,
            pageContainer.bounds.width > 0
        else { return }

        let visiblePage: Page = scrollView.contentOffset.x < pageTravelDistance * 0.5
            ? .terminal
            : .qwerty
        guard visiblePage != currentPage else { return }
        currentPage = visiblePage
        updatePageControl()
    }

    @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
        let width = pageTravelDistance
        switch gesture.state {
        case .began:
            cancelPagingHint(settleOnCurrentPage: false)
            pageContainer.layer.removeAllAnimations()
            panStartOffset = pageContainer.contentOffset.x

        case .changed:
            let translation = gesture.translation(in: pageContainer).x
            let offset = min(max(panStartOffset - translation, 0), width)
            pageContainer.contentOffset = CGPoint(x: offset, y: 0)

        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: pageContainer).x
            let projectedOffset = pageContainer.contentOffset.x - velocity * 0.16
            setPage(projectedOffset >= width * 0.5 ? .qwerty : .terminal, animated: true)

        default:
            break
        }
    }

    private func playPagingHintIfNeeded() {
        guard shouldPlayPagingHintWhenAttached else { return }
        guard !UIAccessibility.isReduceMotionEnabled else {
            shouldPlayPagingHintWhenAttached = false
            return
        }
        guard currentPage == .terminal, pageContainer.bounds.width > 0 else { return }

        shouldPlayPagingHintWhenAttached = false
        isPlayingPagingHint = true
        let peek = min(78, pageContainer.bounds.width * 0.21)

        UIView.animate(
            withDuration: 0.24,
            delay: 0.12,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: {
                self.pageContainer.contentOffset = CGPoint(x: peek, y: 0)
            },
            completion: { finished in
                guard finished, self.isPlayingPagingHint else { return }
                UIView.animate(
                    withDuration: 0.32,
                    delay: 0,
                    usingSpringWithDamping: 0.82,
                    initialSpringVelocity: 0.2,
                    options: [.allowUserInteraction, .beginFromCurrentState],
                    animations: {
                        self.pageContainer.contentOffset = .zero
                    },
                    completion: { _ in self.isPlayingPagingHint = false }
                )
            }
        )
    }

    private func cancelPagingHint(settleOnCurrentPage: Bool) {
        guard isPlayingPagingHint else { return }

        let visibleOffset = pageContainer.layer.presentation()?.bounds.origin.x
            ?? pageContainer.contentOffset.x
        pageContainer.layer.removeAllAnimations()
        isPlayingPagingHint = false

        let targetOffset = settleOnCurrentPage
            ? (currentPage == .terminal ? 0 : pageTravelDistance)
            : min(max(visibleOffset, 0), pageTravelDistance)
        pageContainer.setContentOffset(CGPoint(x: targetOffset, y: 0), animated: false)
    }

    private func updatePageControl() {
        pageControl.currentPage = currentPage.rawValue
        pageControl.accessibilityValue = currentPage == .terminal
            ? "Terminal keys, page 1 of 2"
            : "QWERTY, page 2 of 2"
    }
}

private extension TerminalModifierState {
    func isActive(_ modifier: TerminalModifier) -> Bool {
        switch modifier {
        case .shift: shift
        case .ctrl: ctrl
        case .alt: alt
        case .command: command
        }
    }
}

private struct KeyDescription {
    enum Content {
        case title(String)
        case character(String)
        case symbol(String)
    }

    enum Action {
        case key(TerminalInputKey)
        case modifier(TerminalModifier)
    }

    let content: Content
    let action: Action
    let accessibilityLabel: String
    var width: CGFloat = 1

    var identifier: String {
        "terminal-key-" + accessibilityLabel
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    static func text(
        _ title: String,
        _ key: TerminalInputKey,
        _ accessibilityLabel: String,
        width: CGFloat = 1
    ) -> Self {
        Self(
            content: .title(title), action: .key(key),
            accessibilityLabel: accessibilityLabel, width: width
        )
    }

    static func character(_ key: String, width: CGFloat = 1) -> Self {
        Self(
            content: .character(key), action: .key(.text(key)),
            accessibilityLabel: key.uppercased(), width: width
        )
    }

    static func symbol(
        _ symbol: String,
        _ key: TerminalInputKey,
        _ accessibilityLabel: String,
        width: CGFloat = 1
    ) -> Self {
        Self(
            content: .symbol(symbol), action: .key(key),
            accessibilityLabel: accessibilityLabel, width: width
        )
    }

    static func modifier(
        _ title: String,
        _ modifier: TerminalModifier,
        _ accessibilityLabel: String,
        width: CGFloat = 1
    ) -> Self {
        Self(
            content: .title(title), action: .modifier(modifier),
            accessibilityLabel: accessibilityLabel, width: width
        )
    }
}

private final class TerminalKeyboardButton: UIButton {
    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }

    init() {
        super.init(frame: .zero)
        tintColor = TTYBuildTheme.uiContent
        setTitleColor(TTYBuildTheme.uiContent, for: .normal)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateAppearance() {
        backgroundColor = if isSelected {
            TTYBuildTheme.uiSelection
        } else if isHighlighted {
            TTYBuildTheme.uiSelection.withAlphaComponent(0.7)
        } else {
            TTYBuildTheme.uiSurface
        }
        layer.borderWidth = isSelected ? 1 : 0
        layer.borderColor = TTYBuildTheme.uiContent.withAlphaComponent(0.92).cgColor
    }
}
