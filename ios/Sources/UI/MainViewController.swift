import Combine
import PedalsKit
import UIKit

/// Process-local only: a fresh app launch creates a fresh hint opportunity,
/// while controller/view reconstruction during the same run cannot replay it.
@MainActor
private enum TerminalKeyboardPagingHintMemory {
    private static var hasShown = false

    static func claim() -> Bool {
        guard !hasShown else { return false }
        hasShown = true
        return true
    }
}

enum TerminalFocusPolicy {
    /// Paging preserves the keyboard as-is: a page change refocuses only when
    /// the keyboard was up on the page being left, so a dismissed keyboard
    /// stays dismissed across swipes.
    static func shouldFocus(
        applicationActive: Bool,
        restoreFocus: Bool,
        pageChanged: Bool,
        hasBeenFocused: Bool,
        isFirstResponder: Bool,
        keyboardVisible: Bool
    ) -> Bool {
        applicationActive
            && !isFirstResponder
            && (restoreFocus || !hasBeenFocused || (pageChanged && keyboardVisible))
    }
}

/// Safari-style main screen: floating glass tab strip on top, the active
/// page filling the screen beneath it, and a persistent glass input toolbar
/// at the bottom that rides above the keyboard while a terminal is visible.
/// Page 0 is the Home overview; one terminal page follows per session
/// (terminals can live on different computers). Horizontal pans page between
/// them, with the tab strip following.
@MainActor
final class MainViewController: UIViewController {
    private let services: AppServices
    private var manager: TerminalManager { services.terminals }

    /// Identity of one horizontally pageable screen.
    enum PageID: Hashable {
        case home
        case terminal(TerminalID)
    }

    /// One page per terminal: the Ghostty host plus its freeze/loading mask,
    /// wrapped in a container that the pan gesture slides around.
    @MainActor
    private final class Page {
        let host: TerminalHost
        let container = UIView()
        let overlay = TerminalStatusOverlay()
        var hasBeenFocused = false
        /// True once the emulator holds a replay base plus every stdout byte
        /// since. Pooled hidden pages are kept fed, so paging back to an
        /// intact stream needs no replay; eviction, background sleep,
        /// reconnects, and foreign resizes all break the stream.
        var streamIntact = false

        init(host: TerminalHost) {
            self.host = host
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.view.frame = container.bounds
            container.addSubview(host.view)
            overlay.translatesAutoresizingMaskIntoConstraints = true
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.frame = container.bounds
            container.addSubview(overlay)
            // Standalone TerminalHost instances are interactive by default for
            // previews/tests. A pageable host starts asleep until this
            // controller explicitly presents it.
            host.setActive(false)
        }
    }

    private let pagesContainer = UIView()
    private var pages: [TerminalID: Page] = [:]
    private var orderedIds: [TerminalID] = []
    /// Cold launch lands on Home; terminal activation never steals it (only
    /// explicit navigation — taps, pans, own creations — switches pages).
    private var visiblePage: PageID = .home
    /// The page whose visibility/focus lifecycle was last committed. Animated
    /// navigation updates `visiblePage` before settling; keeping this separate
    /// lets completion transfer first responder from the genuinely old page.
    private var presentedPage: PageID = .home
    private var isApplicationActive = UIApplication.shared.applicationState == .active
    private var visibleId: TerminalID? {
        if case .terminal(let id) = visiblePage { return id }
        return nil
    }

    private lazy var homeController = HomeViewController(manager: services.terminals)
    private var homeView: UIView { homeController.view }
    /// Home first, then the terminals in tab order.
    private var pageOrder: [PageID] { [.home] + orderedIds.map(PageID.terminal) }

    private let tabStrip = TabStripView()
    private let toastView = TerminalToastView()
    private var toastTask: Task<Void, Never>?
    private let toolbar = TerminalToolbar()
    private let terminalKeyboard = TerminalKeyboardView()
    private var isTerminalKeyboardEnabled = false
    private var toolbarBottomConstraint: NSLayoutConstraint!
    private var pagesBottomToToolbarConstraint: NSLayoutConstraint!
    private var pagesBottomToViewConstraint: NSLayoutConstraint!

    private let unpairedView = UnpairedStateView()

    /// Lets the existing Home agent fixture be captured on a clean simulator
    /// without manufacturing a pairing identity. Release builds always show
    /// the real unpaired state.
    private var hidesUnpairedStateForAgentFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PEDALS_HOME_AGENTS_FIXTURE"] == "1"
        #else
        false
        #endif
    }

    /// Bound computer count, taken from the `$computers` EMISSION — never read
    /// `manager.computers` inside a sink (@Published emits during willSet, so
    /// the property still holds the old value there).
    private var computerCount = 0

    /// Tracks the on-screen keyboard (system or terminal replacement) via
    /// keyboard frame notifications; paging reads it to preserve the
    /// keyboard's open/dismissed state across page changes.
    private var isKeyboardVisible = false

    private var panGesture: UIPanGestureRecognizer!
    /// In-flight pan: target index we are dragging toward.
    private var panTarget: Int?
    /// True between the first `.changed` and the end of a pan. While set,
    /// `apply()` defers page-visibility reconciliation so a `sessions`
    /// rebroadcast (title/cwd poll) can't hide the page under the finger.
    private var isPanning = false
    private var deferredApply = false
    /// In-flight settle spring (pan release or animated `switchTo`). Held so a
    /// new pan can stop it mid-flight and take over from the frozen positions
    /// instead of fighting it (the old completion used to reset every frame
    /// under the new gesture's finger).
    private var settleAnimator: UIViewPropertyAnimator?
    /// The other page participating in the settle (sliding out on commit, the
    /// abandoned target on cancel). Still on screen if the settle is
    /// interrupted, so a takeover pan adopts it as its initial candidate.
    private var settleCounterpart: PageID?

    private var cancellables: Set<AnyCancellable> = []

    init(services: AppServices) {
        self.services = services
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PedalsTheme.uiCanvas
        buildLayout()
        bind()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private func buildLayout() {
        // Content: full-bleed from the very top (scrolls under the tab strip)
        // down to the toolbar, so the grid never hides behind the keyboard bar.
        pagesContainer.clipsToBounds = true
        pagesContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pagesContainer)

        // Home: the leftmost, always-existing page.
        addChild(homeController)
        homeView.translatesAutoresizingMaskIntoConstraints = true
        homeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        homeView.frame = pagesContainer.bounds
        pagesContainer.addSubview(homeView)
        homeController.didMove(toParent: self)
        homeController.onSettings = { [weak self] in self?.presentSettings() }
        homeController.onSelectTerminal = { [weak self] id in
            self?.switchTo(.terminal(id), animated: true)
        }

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.onKey = { [weak self] key in
            self?.sendToolbarKey(key)
        }
        toolbar.onModifierToggle = { [weak self] modifier in
            guard let self, let id = visibleId else { return }
            pages[id]?.host.toggleModifier(modifier)
        }
        toolbar.onKeyboardToggle = { [weak self] in self?.toggleTerminalKeyboard() }
        view.addSubview(toolbar)

        terminalKeyboard.onKey = { [weak self] key in
            self?.sendToolbarKey(key)
        }
        terminalKeyboard.onModifierToggle = { [weak self] modifier in
            guard let self, let id = visibleId else { return }
            pages[id]?.host.toggleModifier(modifier)
        }

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelect = { [weak self] id in self?.showTerminal(id) }
        tabStrip.onClose = { [weak self] id in self?.closeTerminal(id) }
        tabStrip.onHome = { [weak self] in self?.switchTo(.home, animated: true) }
        tabStrip.onCreate = { [weak self] in self?.createOnOnlyComputer() }
        tabStrip.setHomeSelected(true)
        view.addSubview(tabStrip)

        toastView.translatesAutoresizingMaskIntoConstraints = false
        toastView.alpha = 0
        toastView.transform = CGAffineTransform(translationX: 0, y: -10)
        view.addSubview(toastView)

        unpairedView.translatesAutoresizingMaskIntoConstraints = false
        unpairedView.onEnterCode = { [weak self] in self?.presentPairingCode() }
        view.addSubview(unpairedView)

        pagesBottomToToolbarConstraint = pagesContainer.bottomAnchor.constraint(
            equalTo: toolbar.topAnchor, constant: -6
        )
        pagesBottomToViewConstraint = pagesContainer.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )
        toolbarBottomConstraint = toolbar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -6
        )

        NSLayoutConstraint.activate([
            // libghostty has no asymmetric content inset, so the grid sits
            // strictly between the tab strip and the toolbar — nothing may
            // cover terminal content.
            pagesContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: 4),
            pagesContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pagesContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pagesBottomToToolbarConstraint,

            tabStrip.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: TabStripView.height),

            toastView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: 10),
            toastView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20
            ),
            toastView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20
            ),

            toolbar.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12
            ),
            toolbar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12
            ),
            toolbarBottomConstraint,
            toolbar.heightAnchor.constraint(equalToConstant: TerminalToolbar.height),

            unpairedView.topAnchor.constraint(equalTo: view.topAnchor),
            unpairedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            unpairedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            unpairedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.minimumNumberOfTouches = 1
        panGesture.maximumNumberOfTouches = 1
        panGesture.delaysTouchesBegan = false
        panGesture.delaysTouchesEnded = false
        pagesContainer.addGestureRecognizer(panGesture)
    }

    // MARK: - Bindings

    private func bind() {
        Publishers.CombineLatest3(
            manager.$terminals,
            manager.$activeID,
            manager.$agentRows
        )
            .sink { [weak self] terminals, activeId, agentRows in
                self?.apply(
                    terminals: terminals,
                    activeId: activeId,
                    agentRows: agentRows
                )
            }
            .store(in: &cancellables)

        manager.outputs
            .sink { [weak self] id, output in self?.handle(id: id, output: output) }
            .store(in: &cancellables)

        manager.exits
            .sink { [weak self] id, code in self?.pages[id]?.host.markExited(code: code) }
            .store(in: &cancellables)

        // NOTE: @Published emits during willSet — inside a sink the source
        // property still holds the OLD value, so overlay state must be
        // computed from the emitted values, never read back off the manager.
        manager.$phases
            .sink { [weak self] phases in
                guard let self else { return }
                reconcileStreamIntegrity(phases: phases)
                updateOverlays(terminals: manager.terminals, phases: phases)
            }
            .store(in: &cancellables)

        manager.$computers
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                guard let self else { return }
                computerCount = count
                let unpaired = count == 0 && !hidesUnpairedStateForAgentFixture
                unpairedView.isHidden = !unpaired
                tabStrip.isHidden = unpaired
                tabStrip.setCreateMenu(count > 1 ? makeCreateMenu() : nil)
                // The tab-title "machine · " prefix depends on the computer
                // count; refresh titles when it crosses the 1↔many boundary
                // even if no session changed (e.g. binding an idle computer).
                apply(terminals: manager.terminals, activeId: manager.activeID)
            }
            .store(in: &cancellables)

        // A terminal this device just created: switch to its page (from Home
        // too — creating is explicit navigation).
        manager.ownCreations
            .sink { [weak self] id in self?.showTerminal(id) }
            .store(in: &cancellables)

        manager.errors
            .sink { [weak self] message in self?.presentError(message) }
            .store(in: &cancellables)

        services.pendingReverseClaims
            .receive(on: DispatchQueue.main)
            .sink { [weak self] claims in
                self?.presentReversePairingCardIfNeeded(claims: claims)
            }
            .store(in: &cancellables)

        manager.notices
            .sink { [weak self] message in self?.showToast(message) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.suspendTerminalPresentation() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resumeTerminalPresentation() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.updateToolbarKeyboardVisibility(from: notification)
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.updateToolbarKeyboardVisibility(from: notification, forceHidden: true)
            }
            .store(in: &cancellables)
    }

    private func updateToolbarKeyboardVisibility(
        from notification: Notification,
        forceHidden: Bool = false
    ) {
        let userInfo = notification.userInfo ?? [:]
        let visible: Bool
        var localKeyboardFrame: CGRect?
        if forceHidden {
            visible = false
        } else if let screenFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let localFrame = view.convert(screenFrame, from: nil)
            localKeyboardFrame = localFrame
            visible = view.bounds.intersection(localFrame).height > 1
        } else {
            return
        }
        isKeyboardVisible = visible

        let safeAreaBottom = view.safeAreaLayoutGuide.layoutFrame.maxY
        let keyboardTop = localKeyboardFrame.map {
            min(max($0.minY, view.bounds.minY), view.bounds.maxY)
        } ?? safeAreaBottom
        toolbarBottomConstraint.constant = visible
            ? keyboardTop - safeAreaBottom - 6
            : -6

        // `UIKeyboardLayoutGuide` animates its presentation frame while
        // Auto Layout exposes the final model frame. An IOSurface-backed
        // terminal cannot derive a valid contentsScale from those two
        // different heights. Apply the terminal geometry atomically to the
        // notification's final keyboard frame; the keyboard itself continues
        // using the system animation.
        UIView.performWithoutAnimation {
            view.layoutIfNeeded()
        }

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25
        let curve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
            .uintValue ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        toolbar.setKeyboardVisible(
            visible,
            animated: view.window != nil,
            duration: duration,
            options: options
        )
    }

    private func handle(id: TerminalID, output: TerminalManager.Output) {
        guard let page = pages[id] else { return }
        switch output {
        case .replay(let data):
            page.host.feedReplay(data)
            // A replay resets and refeeds the emulator, so it now holds the
            // snapshot base; subsequent stdout keeps it in sync.
            page.streamIntact = true
            // Sync the daemon-side grid to this device's current geometry
            // (the replay was rendered for whoever attached last).
            if let cols = page.host.cols, let rows = page.host.rows {
                manager.sendResize(id, cols: cols, rows: rows)
            }
        case .stdout(let data):
            page.host.feed(data)
        case .remoteResize(let cols, let rows):
            // The daemon is formatting output for a grid this emulator never
            // applied (another client's resize). The echoed authoritative
            // resize is not re-parsable state, so the stream is stale until
            // the next replay. Our own resizes echo back with the grid the
            // emulator just applied and are a no-op here.
            if page.host.cols != cols || page.host.rows != rows {
                page.streamIntact = false
            }
        case .hostRestored:
            // The relay dropped client→host frames while the daemon socket
            // was gone. The grid announcement is the one lost frame type that
            // never self-heals, so repeat it; the daemon treats a same-size
            // resize as a no-op.
            if let cols = page.host.cols, let rows = page.host.rows {
                manager.sendResize(id, cols: cols, rows: rows)
            }
        }
    }

    /// A page's emulator mirrors the daemon stream only while its channel has
    /// been continuously live: eviction, background sleep, and reconnects all
    /// drop bytes that only the next replay restores. (`.live` is reached via
    /// a replay, which re-marks the stream intact through `handle(id:output:)`.)
    private func reconcileStreamIntegrity(phases: [TerminalID: TerminalChannel.Phase]) {
        for (id, page) in pages where page.streamIntact {
            if phases[id] != .live {
                page.streamIntact = false
            }
        }
    }

    // MARK: - Terminal/page reconciliation

    private func apply(
        terminals: [Terminal],
        activeId: TerminalID?,
        agentRows emittedAgentRows: [AgentRow]? = nil
    ) {
        // A pan drives page frames/visibility by hand; a mid-gesture rebuild
        // would hide the page being dragged. Re-run once the gesture settles.
        if isPanning {
            deferredApply = true
            return
        }
        let agentRows = emittedAgentRows ?? manager.agentRows
        let previousOrderedIds = orderedIds
        let ids = Set(terminals.map(\.id))
        orderedIds = terminals.map(\.id)

        for (id, page) in pages where !ids.contains(id) {
            if page.host.view.isFirstResponder {
                page.host.view.resignFirstResponder()
            }
            page.container.removeFromSuperview()
            pages.removeValue(forKey: id)
        }

        for terminal in terminals where pages[terminal.id] == nil {
            let page = Page(host: TerminalHost(controller: services.makeTerminalController()))
            let id = terminal.id
            page.host.onInput = { [weak self] data in
                self?.manager.sendStdin(id, data: data)
            }
            page.host.onResize = { [weak self] cols, rows in
                self?.manager.sendResize(id, cols: cols, rows: rows)
            }
            page.host.onModifierStateChange = { [weak self] state in
                guard let self, visibleId == id else { return }
                toolbar.setModifierState(state)
                terminalKeyboard.setModifierState(state)
            }
            page.host.onFocusChange = { [weak self] focused in
                guard let self, isApplicationActive, !focused, visibleId == id else { return }
                exitTerminalKeyboardMode()
            }
            pages[id] = page

            page.container.isHidden = true
            page.container.translatesAutoresizingMaskIntoConstraints = true
            page.container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.container.frame = pagesContainer.bounds
            pagesContainer.addSubview(page.container)

            // The channel can go live while apply() is deferred by a pan — the
            // replay arrived with no page to feed and was dropped. Fetch a
            // fresh snapshot so the new page isn't permanently blank.
            if manager.phases[id] == .live {
                manager.requestReplay(id)
            }
        }

        // The visible terminal vanished (closed / computer offline): fall back
        // to its closest surviving predecessor, then successor, before using
        // the manager's active terminal. Home itself is never yanked away by
        // data changes.
        if case .terminal(let id) = visiblePage, pages[id] == nil {
            let oldIndex = previousOrderedIds.firstIndex(of: id)
            let predecessor = oldIndex.flatMap { index in
                previousOrderedIds[..<index].reversed().first { pages[$0] != nil }
            }
            let successor = oldIndex.flatMap { index in
                previousOrderedIds.dropFirst(index + 1).first { pages[$0] != nil }
            }
            if let replacement = predecessor ?? successor {
                visiblePage = .terminal(replacement)
            } else if let activeId, pages[activeId] != nil {
                visiblePage = .terminal(activeId)
            } else {
                visiblePage = .home
            }
        }
        setVisiblePage(visiblePage)
        updateOverlays(terminals: terminals, phases: manager.phases)

        let showComputer = computerCount > 1
        tabStrip.update(
            tabs: terminals.map {
                let agent = TerminalManager.agent(for: $0.id, in: agentRows)
                return .init(
                    id: $0.id,
                    title: showComputer ? "\($0.computerName) · \($0.info.title)" : $0.info.title,
                    alive: $0.info.alive && !$0.closing,
                    agent: agent?.agent,
                    agentState: agent?.state
                )
            },
            activeId: visibleId
        )
    }

    private func container(for page: PageID) -> UIView? {
        switch page {
        case .home: homeView
        case .terminal(let id): pages[id]?.container
        }
    }

    /// Idempotent on purpose: a `created` echo can arrive BEFORE the terminal
    /// list does (create flow), so the first call may record a page that
    /// doesn't exist yet — the re-run after page creation must still unhide it.
    private func setVisiblePage(
        _ page: PageID,
        restoreFocus: Bool = false
    ) {
        let previousPage = presentedPage
        visiblePage = page
        homeView.isHidden = page != .home
        homeView.frame = pagesContainer.bounds
        for (pageId, terminalPage) in pages {
            let isPresented = PageID.terminal(pageId) == page && isApplicationActive
            terminalPage.host.setActive(isPresented)
            terminalPage.container.isHidden = PageID.terminal(pageId) != page
            terminalPage.container.frame = pagesContainer.bounds
        }
        if case .terminal(let id) = page, let terminalPage = pages[id] {
            if isApplicationActive {
                // The page is ready before opening its one live data channel,
                // so the reconnect replay cannot be dropped into a sleeping
                // renderer.
                manager.activate(id)
            } else {
                manager.sleepAllChannels()
            }
            terminalPage.host.setReplacementInputView(
                isTerminalKeyboardEnabled ? terminalKeyboard : nil
            )
            toolbar.setModifierState(terminalPage.host.modifierState)
            terminalKeyboard.setModifierState(terminalPage.host.modifierState)
            if TerminalFocusPolicy.shouldFocus(
                applicationActive: isApplicationActive,
                restoreFocus: restoreFocus,
                pageChanged: previousPage != page,
                hasBeenFocused: terminalPage.hasBeenFocused,
                isFirstResponder: terminalPage.host.view.isFirstResponder,
                keyboardVisible: isKeyboardVisible
            ) {
                terminalPage.host.view.becomeFirstResponder()
            }
            terminalPage.hasBeenFocused = true
            // Unhiding does not fire didMoveToWindow, so nothing else
            // repaints output that arrived while the view was hidden.
            if isApplicationActive {
                terminalPage.host.kickRender()
                // A page that stayed pooled was fed every byte while hidden;
                // replaying would reset and reparse the whole scrollback for
                // nothing. Only a stale stream (slept, reconnected, or
                // resized by another client) needs a fresh snapshot.
                if !terminalPage.streamIntact {
                    manager.requestReplay(id)
                }
            }
        } else {
            // Home keeps the pooled channels warm so paging back into a
            // terminal is instant; only backgrounding sleeps the data plane.
            if !isApplicationActive {
                manager.sleepAllChannels()
            }
            toolbar.setModifierState(TerminalModifierState())
            terminalKeyboard.setModifierState(TerminalModifierState())
            if page == .home {
                // Neither the system keyboard nor the terminal keyboard may
                // cover Home.
                exitTerminalKeyboardMode()
                view.endEditing(true)
            }
        }
        presentedPage = page
        updateTerminalChromeVisibility()
        tabStrip.setHomeSelected(page == .home)
    }

    private func suspendTerminalPresentation() {
        guard isApplicationActive else { return }
        isApplicationActive = false
        for page in pages.values {
            page.host.setActive(false)
        }
        manager.sleepAllChannels()
    }

    private func resumeTerminalPresentation() {
        guard !isApplicationActive else {
            manager.kickAll()
            return
        }
        isApplicationActive = true
        manager.kickAll()
        // Reattach the foreground renderer before its data channel, force a
        // replay to cover everything produced while asleep, and restore input
        // ownership to the terminal the user can actually see.
        setVisiblePage(visiblePage, restoreFocus: visibleId != nil)
    }

    // MARK: - Page navigation

    /// Closing the visible tab commits its replacement immediately, before
    /// the daemon asynchronously confirms removal. Besides feeling direct,
    /// this prevents the removal emission from ever presenting Home between
    /// the old and replacement terminal pages.
    private func closeTerminal(_ id: TerminalID) {
        guard manager.terminal(id)?.closing == false else { return }
        if visibleId == id {
            if let replacementID = TerminalManager.replacementID(
                afterClosing: id,
                in: manager.terminals
            ) {
                showTerminal(replacementID)
            } else {
                setVisiblePage(.home)
                tabStrip.update(tabs: tabStrip.tabs, activeId: nil)
            }
        }
        manager.closeTerminal(id)
    }

    /// Instant switch (tab strip tap, own-create echo).
    private func showTerminal(_ id: TerminalID) {
        manager.activate(id)
        if isPanning {
            // A pan/slide owns the page frames; the deferred apply() will
            // reconcile visibility to `visiblePage` once it settles.
            visiblePage = .terminal(id)
            deferredApply = true
            return
        }
        setVisiblePage(.terminal(id))
        tabStrip.update(tabs: tabStrip.tabs, activeId: id)
    }

    /// Animated slide (home pill, Home terminal rows).
    private func switchTo(_ page: PageID, animated: Bool) {
        guard page != visiblePage else { return }
        guard animated, !isPanning,
              let fromIndex = pageOrder.firstIndex(of: visiblePage),
              let toIndex = pageOrder.firstIndex(of: page),
              let fromView = container(for: visiblePage),
              let toView = container(for: page),
              pagesContainer.bounds.width > 0
        else {
            if case .terminal(let id) = page {
                showTerminal(id)
            } else if isPanning {
                // Same deferral as showTerminal: a pan/settle owns the page
                // frames; the completion (via deferred apply) reconciles.
                visiblePage = page
                deferredApply = true
            } else {
                setVisiblePage(page)
                tabStrip.update(tabs: tabStrip.tabs, activeId: nil)
            }
            return
        }

        // Defer apply() for the whole slide, exactly like a pan settle;
        // commit the model first so any activate-driven emission reconciles
        // toward the target page.
        isPanning = true
        let fromPage = visiblePage
        visiblePage = page
        if case .terminal(let id) = page {
            manager.activate(id)
        }
        let width = pagesContainer.bounds.width
        let direction: CGFloat = toIndex > fromIndex ? 1 : -1
        toView.isHidden = false
        toView.frame = pagesContainer.bounds.offsetBy(dx: direction * width, dy: 0)
        settleCounterpart = fromPage
        let animator = UIViewPropertyAnimator(
            duration: 0.42,
            timingParameters: UISpringTimingParameters(
                dampingRatio: 0.86, initialVelocity: CGVector(dx: 0.3, dy: 0)
            )
        )
        animator.addAnimations {
            fromView.frame = self.pagesContainer.bounds.offsetBy(dx: -direction * width, dy: 0)
            toView.frame = self.pagesContainer.bounds
        }
        animator.addCompletion { position in
            guard position == .end else { return }
            self.settleAnimator = nil
            self.settleCounterpart = nil
            self.isPanning = false
            let missedApply = self.deferredApply
            self.deferredApply = false
            // Re-read visiblePage: a tab tap mid-slide may have retargeted it.
            self.setVisiblePage(self.visiblePage)
            self.tabStrip.update(tabs: self.tabStrip.tabs, activeId: self.visibleId)
            if missedApply {
                self.apply(terminals: self.manager.terminals, activeId: self.manager.activeID)
            }
        }
        animator.startAnimation()
        settleAnimator = animator
    }

    private func sendToolbarKey(_ key: TerminalInputKey) {
        guard let id = visibleId, let page = pages[id] else { return }
        page.host.sendToolbarKey(key)
    }

    private func toggleTerminalKeyboard() {
        guard let id = visibleId, let page = pages[id] else { return }
        isTerminalKeyboardEnabled.toggle()
        toolbar.setTerminalKeyboardEnabled(isTerminalKeyboardEnabled)
        if isTerminalKeyboardEnabled {
            terminalKeyboard.prepareForPresentation(
                showPagingHint: TerminalKeyboardPagingHintMemory.claim()
            )
        }
        page.host.setReplacementInputView(
            isTerminalKeyboardEnabled ? terminalKeyboard : nil
        )
        if !page.host.view.isFirstResponder {
            page.host.view.becomeFirstResponder()
        }
    }

    /// Closing the expanded keyboard is also an exit from that mode. Without
    /// this reset, the pinned button remains selected and the next terminal
    /// focus unexpectedly opens the expanded keyboard again.
    private func exitTerminalKeyboardMode() {
        guard isTerminalKeyboardEnabled else { return }
        isTerminalKeyboardEnabled = false
        toolbar.setTerminalKeyboardEnabled(false)
        guard let id = visibleId, let page = pages[id] else { return }
        page.host.setReplacementInputView(nil)
    }

    /// Terminal chrome (bottom toolbar + terminal keyboard) exists only while
    /// a terminal page is visible; Home is chrome-free.
    private func updateTerminalChromeVisibility() {
        let shouldShow = visibleId != nil && computerCount > 0
        toolbar.isHidden = !shouldShow

        if shouldShow {
            pagesBottomToViewConstraint.isActive = false
            pagesBottomToToolbarConstraint.isActive = true
        } else {
            pagesBottomToToolbarConstraint.isActive = false
            pagesBottomToViewConstraint.isActive = true
            view.endEditing(true)
            toolbar.setKeyboardVisible(false, animated: false)
            toolbar.setModifierState(TerminalModifierState())
            terminalKeyboard.setModifierState(TerminalModifierState())
        }
    }

    private func updateOverlays(terminals: [Terminal], phases: [TerminalID: TerminalChannel.Phase]) {
        for (id, page) in pages {
            let mode: TerminalStatusOverlay.Mode
            if terminals.first(where: { $0.id == id })?.closing == true {
                mode = .closing
            } else {
                switch phases[id] {
                case .connecting: mode = .connecting
                case .reconnecting: mode = .reconnecting
                case .live: mode = .hidden
                // Asleep (pooled out) or never attached: switching to the tab
                // opens a channel immediately, so show the loading state.
                case nil: mode = id == visibleId ? .connecting : .hidden
                }
            }
            page.overlay.setMode(mode)
        }
    }

    // MARK: - Create

    /// Direct + tap when 0–1 computers are bound (the multi-computer menu is
    /// installed via `setCreateMenu` otherwise).
    private func createOnOnlyComputer() {
        guard let computer = manager.computers.first else { return }
        create(on: computer.id)
    }

    private func create(on computerID: String) {
        // The picker menu already disables offline computers; this covers the
        // single-computer and empty-state paths (and races): a create sent to
        // an absent host is dropped by the relay and would fail silently.
        guard let computer = manager.computer(id: computerID) else { return }
        guard computer.hostOnline else {
            presentError("“\(computer.displayName)” is offline.")
            return
        }
        let active = visibleId.flatMap { pages[$0] }?.host
        manager.createTerminal(
            on: computerID,
            cols: Int(active?.cols ?? 120),
            rows: Int(active?.rows ?? 40)
        )
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(
            title: "Terminal Error", message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastView.setMessage(message)
        view.bringSubviewToFront(toastView)
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.2
        ) {
            self.toastView.alpha = 1
            self.toastView.transform = .identity
        }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.2) {
                self.toastView.alpha = 0
                self.toastView.transform = CGAffineTransform(translationX: 0, y: -8)
            }
        }
    }

    /// Menu listing every bound computer; rebuilt each presentation so names
    /// and connection states are current.
    private func makeCreateMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { return completion([]) }
                let actions = manager.computers.map { computer in
                    let online = computer.hostOnline
                    let action = UIAction(
                        title: computer.displayName,
                        image: UIImage(systemName: online ? "desktopcomputer" : "wifi.slash"),
                        attributes: online ? [] : [.disabled],
                        state: visibleId?.computerID == computer.id ? .on : .off
                    ) { [weak self] _ in
                        self?.create(on: computer.id)
                    }
                    if !online { action.subtitle = "Offline" }
                    return action
                }
                completion(actions)
            }
        ])
    }

    // MARK: - Horizontal pan between pages (Home + terminals)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let order = pageOrder
        guard let activeIndex = order.firstIndex(of: visiblePage),
              let activeView = container(for: visiblePage)
        else { return }

        let width = pagesContainer.bounds.width
        let tx = gesture.translation(in: pagesContainer).x
        // Dragging left (tx < 0) reveals the NEXT page, and vice versa.
        let direction = tx < 0 ? 1 : -1
        let targetIndex = activeIndex + direction
        let hasTarget = order.indices.contains(targetIndex)
        let targetView = hasTarget ? container(for: order[targetIndex]) : nil
        // The strip only mirrors terminal↔terminal moves (Home has no
        // scrolling pill); page index N is tab index N-1.
        let stripTracks = activeIndex > 0 && targetIndex > 0

        switch gesture.state {
        case .began:
            // Grab an in-flight settle: freeze both pages where they are and
            // let this gesture continue from those positions. Seeding the
            // translation with the active page's frozen offset keeps every
            // tx-derived value (positions, direction, commit thresholds)
            // continuous, so the takeover cannot jump.
            guard let animator = settleAnimator else { break }
            animator.stopAnimation(true)
            settleAnimator = nil
            panTarget = settleCounterpart.flatMap { order.firstIndex(of: $0) }
            settleCounterpart = nil
            gesture.setTranslation(
                CGPoint(x: activeView.frame.origin.x, y: 0), in: pagesContainer
            )

        case .changed:
            isPanning = true
            // Rubber-band when there is no neighbor on that side.
            let effectiveTx = hasTarget ? tx : tx / 3
            activeView.frame.origin.x = effectiveTx

            if let targetView, hasTarget {
                if panTarget != targetIndex {
                    // Direction changed mid-gesture: hide the old candidate.
                    if let old = panTarget, order.indices.contains(old),
                       old != targetIndex, let oldView = container(for: order[old])
                    {
                        oldView.isHidden = true
                    }
                    panTarget = targetIndex
                    targetView.isHidden = false
                }
                targetView.frame = pagesContainer.bounds.offsetBy(
                    dx: effectiveTx + CGFloat(direction) * width, dy: 0
                )
                if stripTracks {
                    tabStrip.setSwitchProgress(
                        from: activeIndex - 1, to: targetIndex - 1,
                        progress: abs(effectiveTx) / width
                    )
                }
            }

        case .ended, .cancelled:
            // Keep apply() deferred through the settle animation too — an active
            // page hasn't been committed yet, so a mid-animation rebuild would
            // hide the page sliding in. Cleared in the completion blocks.
            let velocity = gesture.velocity(in: pagesContainer).x
            let commit = hasTarget
                && (abs(tx) > width * 0.35 || abs(velocity) > 700)
                && (velocity == 0 || (velocity < 0) == (direction == 1))

            if commit, let targetView, gesture.state == .ended {
                let targetPage = order[targetIndex]
                // Settle the tab strip in parallel with the page slide (same
                // spring) so they track; the completion's model update then
                // re-animates nothing.
                if stripTracks {
                    tabStrip.commitSwitch(
                        to: targetIndex - 1,
                        duration: 0.42, damping: 0.86,
                        initialVelocity: abs(velocity) / width
                    )
                }
                // Commit the model NOW, not in the completion — a pan that
                // begins mid-settle must see the page under the finger as the
                // active one. activate() no-ops if the target was removed
                // mid-gesture; setVisiblePage + the deferred apply() reconcile
                // once the settle lands.
                let fromPage = visiblePage
                visiblePage = targetPage
                if case .terminal(let id) = targetPage {
                    manager.activate(id)
                }
                settleCounterpart = fromPage
                let animator = UIViewPropertyAnimator(
                    duration: 0.42,
                    timingParameters: UISpringTimingParameters(
                        dampingRatio: 0.86,
                        initialVelocity: CGVector(dx: abs(velocity) / width, dy: 0)
                    )
                )
                animator.addAnimations {
                    activeView.frame = self.pagesContainer.bounds.offsetBy(
                        dx: CGFloat(-direction) * width, dy: 0
                    )
                    targetView.frame = self.pagesContainer.bounds
                }
                animator.addCompletion { position in
                    guard position == .end else { return }
                    self.settleAnimator = nil
                    self.settleCounterpart = nil
                    self.panTarget = nil
                    self.isPanning = false
                    let missedApply = self.deferredApply
                    self.deferredApply = false
                    // Re-read visiblePage: a tab tap mid-settle may have
                    // retargeted it.
                    self.setVisiblePage(self.visiblePage)
                    self.tabStrip.update(tabs: self.tabStrip.tabs, activeId: self.visibleId)
                    if missedApply {
                        self.apply(terminals: self.manager.terminals, activeId: self.manager.activeID)
                    }
                }
                animator.startAnimation()
                settleAnimator = animator
            } else {
                settleCounterpart = hasTarget && targetView != nil
                    ? order[targetIndex] : nil
                let animator = UIViewPropertyAnimator(
                    duration: 0.38,
                    timingParameters: UISpringTimingParameters(
                        dampingRatio: 0.85, initialVelocity: CGVector(dx: 0.3, dy: 0)
                    )
                )
                animator.addAnimations {
                    activeView.frame = self.pagesContainer.bounds
                    if let targetView, hasTarget {
                        targetView.frame = self.pagesContainer.bounds.offsetBy(
                            dx: CGFloat(direction) * width, dy: 0
                        )
                    }
                }
                animator.addCompletion { position in
                    guard position == .end else { return }
                    self.settleAnimator = nil
                    self.settleCounterpart = nil
                    let order = self.pageOrder
                    if let target = self.panTarget,
                       order.indices.contains(target),
                       order[target] != self.visiblePage
                    {
                        self.container(for: order[target])?.isHidden = true
                    }
                    self.panTarget = nil
                    self.isPanning = false
                    // A rebroadcast was skipped mid-gesture; reconcile now that
                    // we settled back on the same page.
                    if self.deferredApply {
                        self.deferredApply = false
                        self.apply(terminals: self.manager.terminals, activeId: self.manager.activeID)
                    }
                }
                animator.startAnimation()
                settleAnimator = animator
                tabStrip.cancelSwitchProgress()
            }

        default:
            break
        }
    }

    // MARK: - Pairing entry points

    private func presentPairingCode() {
        let controller = PairingCodeViewController()
        let services = services
        controller.onPair = { code in
            try await services.bind(code: code)
        }
        controller.installCommandProvider = { await services.installCommand() }
        controller.onAppearForPairing = { services.enablePairingNotifications() }
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    // MARK: - Reverse pairing confirmation

    private var reversePairingCard: ReversePairingConfirmViewController?

    private var reversePairingCardRetryTask: Task<Void, Never>?

    /// One card at a time; the count of further claims shows on the card and
    /// the next one presents as soon as this one resolves.
    private func presentReversePairingCardIfNeeded(claims: [ReversePairingClaim]) {
        guard reversePairingCard == nil, let claim = claims.first else { return }
        if let presented = presentedViewController {
            // The manual code-entry screen just became obsolete — the claim
            // it was waiting for arrived. Replace it with the confirmation.
            if presented is PairingCodeViewController {
                presented.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    presentReversePairingCardIfNeeded(
                        claims: self.services.pendingReverseClaims.value
                    )
                }
                return
            }
            // Another modal (settings, updates…) owns the screen. Retry
            // shortly instead of dropping the presentation.
            reversePairingCardRetryTask?.cancel()
            reversePairingCardRetryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                reversePairingCardRetryTask = nil
                presentReversePairingCardIfNeeded(
                    claims: self.services.pendingReverseClaims.value
                )
            }
            return
        }

        let card = ReversePairingConfirmViewController(
            claim: claim,
            remaining: claims.count - 1
        )
        let services = services
        card.onConfirm = { [weak self, weak card] claim in
            card?.show(.working(name: claim.computerName))
            Task { @MainActor in
                do {
                    try await services.confirmReverseClaim(claim)
                    card?.dismiss(animated: true)
                } catch {
                    card?.show(.failed(
                        message: "Couldn't connect “\(claim.computerName)”. Check your connection and try again."
                    ))
                }
            }
        }
        card.onReject = { [weak card] claim in
            // Dismiss immediately; the server-side delete is fired behind it
            // and an unreachable service just lets the claim expire instead.
            card?.dismiss(animated: true)
            Task { @MainActor in
                try? await services.rejectReverseClaim(claim)
            }
        }
        card.onDismissed = { [weak self] in
            self?.reversePairingCard = nil
            // Present the next pending claim, if any.
            self?.presentReversePairingCardIfNeeded(
                claims: self?.services.pendingReverseClaims.value ?? []
            )
        }
        reversePairingCard = card
        present(card, animated: true)
    }

    // MARK: - Settings

    private func presentSettings() {
        let settings = SettingsViewController(services: services)
        present(UINavigationController(rootViewController: settings), animated: true)
    }
}

/// A transient overlay rather than a layout row, so terminal geometry never
/// shifts when a computer goes offline.
private final class TerminalToastView: UIView {
    private let glass = GlassView(interactive: false)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false

        glass.cornerRadius = 16
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .preferredFont(forTextStyle: .subheadline).bold()
        label.textColor = .label
        label.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setMessage(_ message: String) {
        label.text = message
        accessibilityLabel = message
    }
}

private extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

extension MainViewController: UIGestureRecognizerDelegate {
    /// Claim only clearly-horizontal pans; everything else stays with the
    /// terminal (vertical scrollback, taps, long-press selection).
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        guard let index = pageOrder.firstIndex(of: visiblePage) else { return false }
        let selectionActive: Bool = {
            guard let id = visibleId, let page = pages[id] else { return false }
            return page.host.isTextSelectionActive
        }()
        let velocity = panGesture.velocity(in: pagesContainer)
        return TerminalPagingIntent.shouldBegin(
            velocity: velocity,
            currentIndex: index,
            pageCount: pageOrder.count,
            selectionActive: selectionActive
        )
    }

    /// The terminal's own recognizers (touch scroll, taps) must wait for the
    /// horizontal pan to fail; it fails immediately for vertical movement, so
    /// scrollback stays responsive.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === panGesture
            && otherGestureRecognizer.view?.isDescendant(of: pagesContainer) == true
    }
}

/// Keeps a diagonal terminal scroll from being mistaken for page navigation.
/// The boundary check also prevents a one-page/boundary rubber-band from
/// stealing a scroll that cannot possibly switch terminals.
enum TerminalPagingIntent {
    static func shouldBegin(
        velocity: CGPoint,
        currentIndex: Int,
        pageCount: Int,
        selectionActive: Bool
    ) -> Bool {
        guard !selectionActive, pageCount > 1,
              currentIndex >= 0, currentIndex < pageCount
        else { return false }

        let horizontal = abs(velocity.x)
        let vertical = abs(velocity.y)
        guard horizontal > vertical * 1.75 else { return false }

        // Positive x reveals the previous page; negative x reveals the next.
        if velocity.x > 0, currentIndex == 0 { return false }
        if velocity.x < 0, currentIndex == pageCount - 1 { return false }
        return velocity.x != 0
    }
}
