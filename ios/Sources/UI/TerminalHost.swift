import Foundation
import GhosttyTerminal
import UIKit

/// One live Ghostty emulator + view for a single remote session. Instances stay
/// in the view hierarchy (hidden when inactive) so switching sessions is instant
/// and scrollback survives.
@MainActor
final class TerminalHost {
    let view: PedalsTerminalView
    /// Each host owns its controller — see AppServices.makeTerminalController.
    let controller: TerminalController

    /// Keyboard/accessory-bar input bytes, to be sent as `stdin` frames.
    var onInput: ((Data) -> Void)?
    /// Mirrors Pedals' one-shot modifier state into its custom input surfaces.
    var onModifierStateChange: ((TerminalModifierState) -> Void)?
    /// Focus follows UIKit's first responder state, including a terminal tap
    /// that dismisses either the system or Pedals keyboard.
    var onFocusChange: ((Bool) -> Void)?
    /// Grid size changes, to be sent as `resize` frames. Fired only once the
    /// emulator has applied the grid, so a TUI repaint triggered by the frame
    /// can never be parsed against a smaller, stale grid.
    var onResize: ((_ cols: UInt16, _ rows: UInt16) -> Void)?
    /// The grid the emulator has applied — the only size safe to hand to the
    /// daemon. During a layout change this lags `viewport` by one emulator
    /// resize round trip.
    private(set) var cols: UInt16?
    private(set) var rows: UInt16?
    private var viewport: InMemoryTerminalViewport?
    private weak var selectionOverlay: TerminalSelectionOverlay?
    private var selectionStartedWithFirstResponder = false
    private var shiftIsArmed = false
    /// False while this terminal is offscreen or the application is inactive.
    /// The daemon-side PTY keeps running; hidden pooled pages still parse
    /// stdout and replays (rendering stays foreground-only), while slept
    /// channels resync via a full replay on the next activation.
    private(set) var isActive = true

    var isTextSelectionActive: Bool { selectionOverlay != nil }

    /// While a replay snapshot is being digested, the emulator re-answers any
    /// terminal queries (DA, DECRQM, …) contained in the replayed history.
    /// Those auto-responses — all ESC-prefixed control sequences — must not
    /// reach the PTY (the host answered them long ago) or the shell echoes them
    /// as garbage. Only ESC-prefixed writes are muted, so keystrokes the user
    /// types right after a reconnect/replay still go through.
    private var muteInputUntil: Date?

    private let session: InMemoryTerminalSession

    /// Weak trampoline so the `@Sendable` emulator callbacks (fired off-main)
    /// can reach the main-actor host without a retain cycle.
    private final class Relay: @unchecked Sendable {
        weak var host: TerminalHost?
    }

    init(controller: TerminalController) {
        self.controller = controller

        let relay = Relay()
        session = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in relay.host?.handleInput(data) }
            },
            // Ghostty fires this callback while a grid resize is still queued
            // for its termio thread, i.e. *before* the grid is applied to
            // terminal state. Announcing such a grid to the daemon would let
            // the TUI's repaint race the local resize (the original stale-grid
            // corruption), so this event is deliberately unused; applied grids
            // arrive as mode 2048 in-band size reports through `write` instead.
            resize: { _ in }
        )

        view = PedalsTerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        view.delegate = self
        view.backgroundColor = .clear
        view.isOpaque = false
        view.translatesAutoresizingMaskIntoConstraints = false
        // The app docks its own persistent toolbar; drop the keyboard accessory.
        view.inputAccessoryItems = []

        relay.host = self
        view.setStickyModifierChangeHandler { [weak self] in
            guard let self else { return }
            onModifierStateChange?(modifierState)
        }
        view.softwareKeyboardReturnHandler = { [weak self] in
            self?.sendToolbarKey(.enter)
        }
        view.focusChangeHandler = { [weak self] focused in
            self?.onFocusChange?(focused)
        }
        view.setTerminalInteractionEnabled(true)
    }

    var modifierState: TerminalModifierState {
        TerminalModifierState(
            shift: shiftIsArmed,
            ctrl: view.stickyActivation(for: .ctrl) != .inactive,
            alt: view.stickyActivation(for: .alt) != .inactive,
            command: view.stickyActivation(for: .command) != .inactive
        )
    }

    func toggleModifier(_ modifier: TerminalModifier) {
        guard isActive else { return }
        switch modifier {
        case .shift:
            shiftIsArmed.toggle()
            onModifierStateChange?(modifierState)
        case .ctrl:
            toggleOneShotStickyModifier(.ctrl)
        case .alt:
            toggleOneShotStickyModifier(.alt)
        case .command:
            toggleOneShotStickyModifier(.command)
        }
    }

    func sendToolbarKey(_ key: TerminalInputKey) {
        guard isActive else { return }
        switch key {
        case .text(let text):
            // Use libghostty's text path so sticky Control/Option/Command and
            // IME state are consumed by the same machinery as the system keyboard.
            let output = shiftIsArmed
                ? TerminalKeyboardText.applyingShift(to: text)
                : text
            let consumedShift = shiftIsArmed
            shiftIsArmed = false
            view.insertText(output)
            if consumedShift {
                onModifierStateChange?(modifierState)
            }
        case .paste:
            if let text = UIPasteboard.general.string, !text.isEmpty {
                onInput?(Data(text.utf8))
            }
            consumeModifiers()
        case .dismissKeyboard:
            // UIKit may immediately restore the responder while dispatching a
            // control event from inside its inputView. End editing on the next
            // run-loop turn, after the key tap has fully completed.
            DispatchQueue.main.async { [weak view] in
                view?.window?.endEditing(true)
            }
        default:
            let modifiers = activeKeyModifiers
            if let bytes = key.bytes(modifiers: modifiers) {
                onInput?(bytes)
            }
            // Special keys bypass libghostty's text path, so consume the
            // sticky state explicitly after encoding it into the sequence.
            if !modifiers.isEmpty {
                consumeModifiers()
            }
        }
    }

    func setReplacementInputView(_ inputView: UIView?) {
        view.setReplacementInputView(inputView)
        if view.isFirstResponder {
            view.reloadInputViews()
        }
    }

    /// Move this renderer between foreground and sleep. Suspending explicitly
    /// ends selection and first-responder ownership before the page is hidden,
    /// preventing delayed UIKit key events from reaching the old TTY.
    @discardableResult
    func setActive(_ active: Bool) -> Bool {
        guard isActive != active else { return false }
        isActive = active

        if active {
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let container = view.superview {
                view.frame = container.bounds
            }
            view.setTerminalInteractionEnabled(true)
            armSizeReports()
            kickRender()
        } else {
            selectionOverlay?.finish()
            view.setTerminalInteractionEnabled(false)
            // Keep the last rendered geometry frozen. Hidden containers may
            // still follow keyboard/rotation layout, but a sleeping terminal
            // must not resize its Ghostty grid until it is foreground again.
            view.autoresizingMask = []
        }
        return true
    }

    private var activeKeyModifiers: TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        if shiftIsArmed { modifiers.insert(.shift) }
        if view.stickyActivation(for: .ctrl) != .inactive { modifiers.insert(.ctrl) }
        if view.stickyActivation(for: .alt) != .inactive { modifiers.insert(.alt) }
        if view.stickyActivation(for: .command) != .inactive { modifiers.insert(.command) }
        return modifiers
    }

    /// libghostty's built-in sticky state supports double-tap locking. Pedals'
    /// keyboard deliberately uses simpler one-shot modifiers: tap to arm, tap
    /// again to cancel, and any non-modifier key consumes the entire chord.
    private func toggleOneShotStickyModifier(_ modifier: TerminalPublicStickyModifier) {
        if view.stickyActivation(for: modifier) == .inactive {
            view.toggleStickyModifier(modifier)
            return
        }

        // `.armed` may advance to `.locked` when tapped quickly, so continue
        // until the public state reports inactive (at most two transitions).
        for _ in 0 ..< 2 where view.stickyActivation(for: modifier) != .inactive {
            view.toggleStickyModifier(modifier)
        }
    }

    private func consumeModifiers() {
        let hadShift = shiftIsArmed
        shiftIsArmed = false
        view.resetStickyModifiers()
        if hadShift {
            onModifierStateChange?(modifierState)
        }
    }

    /// Feed live remote `stdout` bytes into the emulator. Hidden pooled pages
    /// keep parsing so paging back needs no replay; rendering stays
    /// foreground-only (`kickRender` self-guards on `isActive`).
    func feed(_ data: Data) {
        session.receive(data)
        kickRender()
    }

    /// Feed a `replay` snapshot: reset the emulator first (RIS + erase
    /// scrollback) so a reconnect replay doesn't duplicate earlier output.
    /// Also applied while hidden — a pooled channel's reconnect replay is
    /// what keeps the background emulator in sync.
    func feedReplay(_ data: Data) {
        muteInputUntil = Date().addingTimeInterval(0.5)
        session.receive(Data("\u{1b}c\u{1b}[3J".utf8))
        session.receive(data)
        // Both the RIS above and any reset inside the replayed history clear
        // mode 2048, which the applied-resize pipeline depends on. Re-arming
        // also makes the emulator re-report its current grid, refreshing the
        // daemon after the replay.
        armSizeReports()
        kickRender()
    }

    /// Enable mode 2048 in-band size reports. Ghostty then reports each
    /// applied grid resize through the host input channel — from the same
    /// critical section that mutates terminal state — plus one immediate
    /// report for the current grid. Idempotent.
    private func armSizeReports() {
        session.receive(TerminalSizeReport.enableSequence)
    }

    /// Surface the remote process exit inside the emulator. Also applied
    /// while hidden so a pooled page shows the exit when paged back to.
    func markExited(code: Int) {
        session.finish(exitCode: UInt32(clamping: max(0, code)), runtimeMilliseconds: 0)
        kickRender()
    }

    func kickRender() {
        guard isActive else { return }
        DispatchQueue.main.async { [weak view] in
            view?.fitToSize()
        }
    }

    private func handleInput(_ data: Data) {
        guard isActive else { return }
        // Mode 2048 size reports ride the input channel but are addressed to
        // this host, not the remote pty: each one certifies that the emulator
        // has applied the grid it describes.
        let (data, reports) = TerminalSizeReport.extract(from: data)
        for report in reports {
            handleAppliedResize(report.viewport)
        }
        guard !data.isEmpty else { return }

        if let until = muteInputUntil {
            if Date() < until {
                // Drop only the emulator's query replies. Keyboard input can
                // start with ESC too (bare Esc, arrow keys, Alt+letter) and
                // must pass through even inside the mute window.
                if Self.isEmulatorQueryReply(data) { return }
            } else {
                muteInputUntil = nil
            }
        }
        // Software-key input is consumed by libghostty's sticky path before it
        // reaches this callback. A hardware keyboard, including Simulator's
        // Mac keyboard bridge, bypasses `insertText` and arrives here as one
        // unmodified byte while the sticky state is still armed. Cover that
        // path without touching multi-byte text/paste or emulator replies.
        if data.count == 1,
           let byte = data.first,
           !activeKeyModifiers.isEmpty,
           let modified = activeKeyModifiers.applying(toUnmodifiedByte: byte)
        {
            onInput?(modified)
            view.resetStickyModifiers()
            return
        }

        onInput?(data)
    }

    /// True for the auto-replies the emulator emits while digesting a replay:
    /// CSI reports terminating in `c` (DA), `n` (DSR), `y` (DECRQM), `R` (CPR),
    /// and DCS/OSC responses. Keyboard sequences are different shapes — bare
    /// ESC, `ESC [ A…D` arrows, `ESC O …`, Alt+letter — and all return false.
    private static func isEmulatorQueryReply(_ data: Data) -> Bool {
        guard data.count >= 3, data.first == 0x1b, let last = data.last
        else { return false }
        switch data[data.index(data.startIndex, offsetBy: 1)] {
        case UInt8(ascii: "["):
            return [
                UInt8(ascii: "c"), UInt8(ascii: "n"),
                UInt8(ascii: "y"), UInt8(ascii: "R"),
            ].contains(last)
        case UInt8(ascii: "P"), UInt8(ascii: "]"):
            return true // DCS / OSC response; never keyboard input
        default:
            return false
        }
    }

    /// The emulator applied `viewport` to its grid (mode 2048 size report).
    /// Only now is it safe to announce the size to the daemon: the repaint a
    /// TUI answers with is guaranteed to be parsed against this grid, never a
    /// stale smaller one that would clamp its cursor addressing.
    private func handleAppliedResize(_ viewport: InMemoryTerminalViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }

        noteViewportGeometry(viewport)

        guard cols != viewport.columns || rows != viewport.rows else { return }
        cols = viewport.columns
        rows = viewport.rows
        onResize?(viewport.columns, viewport.rows)
    }

    private func noteViewportGeometry(_ viewport: InMemoryTerminalViewport) {
        let previous = self.viewport
        self.viewport = viewport

        // A selection is tied to the exact Ghostty grid that produced its
        // snapshot. Reflowing it onto a different grid would make the boxes
        // drift from the glyphs, so end only genuinely geometry-changing
        // selections. An identical resize notification is harmless.
        if let previous,
           previous.columns != viewport.columns
            || previous.rows != viewport.rows
            || previous.cellWidthPixels != viewport.cellWidthPixels
            || previous.cellHeightPixels != viewport.cellHeightPixels
        {
            selectionOverlay?.finish()
        }
    }

    private func beginTextSelection(_ request: TerminalTextSelectionRequest) {
        guard isActive else { return }
        selectionOverlay?.finish()
        selectionStartedWithFirstResponder = view.wasFirstResponderBeforeCurrentTouch
        view.setPreservesFirstResponderDuringSelection(true)

        let metrics = viewport ?? InMemoryTerminalViewport(
            columns: cols ?? 1,
            rows: rows ?? 1
        )
        let overlay = TerminalSelectionOverlay(
            viewportText: request.text,
            anchorRange: request.anchorRange,
            sourcePoint: request.sourcePoint,
            viewport: metrics,
            viewportSize: view.bounds.size,
            displayScale: view.window?.screen.nativeScale
                ?? max(1, view.traitCollection.displayScale)
        )
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onScrollRequest = { [weak self] direction, completion in
            self?.scrollSelectionViewport(direction: direction, completion: completion)
        }
        overlay.onFinish = { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            self?.selectionOverlay = nil
            self?.view.setTouchScrollGestureEnabled(true)
            self?.view.setPreservesFirstResponderDuringSelection(false)
            if self?.selectionStartedWithFirstResponder == false {
                self?.view.resignFirstResponder()
            }
        }
        view.setTouchScrollGestureEnabled(false)
        view.addSubview(overlay)
        selectionOverlay = overlay
        overlay.activate()
    }

    private func scrollSelectionViewport(
        direction: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard direction != 0 else {
            completion(session.readViewportText())
            return
        }
        guard view.performBindingAction("scroll_page_lines:\(direction)") else {
            completion(nil)
            return
        }

        // The binding mutates Ghostty immediately, while its Metal layer draws
        // on the next main-loop pass. Update the selection in that same pass so
        // it cannot get one frame ahead of the terminal framebuffer.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            view.fitToSize()
            completion(session.readViewportText())
        }
    }
}

extension TerminalHost: TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceTextSelectionRequestDelegate
{
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        guard isActive else { return }
        // Arm as early as possible so the very first grid announcement to the
        // daemon is already an applied one (the enable answers with a report
        // of the surface's creation grid).
        armSizeReports()
    }

    func terminalDidDetachSurface() {}

    func terminalDidResize(_ size: TerminalGridMetrics) {
        // The delegate reports the grid projected from the new view layout
        // synchronously, before the emulator has applied it. That is exactly
        // right for view-side geometry (a long press during a keyboard
        // animation must not select against a stale grid), and exactly wrong
        // for the daemon: `onResize` waits for the applied-resize report.
        guard isActive, size.columns > 0, size.rows > 0 else { return }
        noteViewportGeometry(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
        // Self-heal: if anything (e.g. a reset in remote output) disabled
        // mode 2048, re-arming here guarantees the grid this layout produces
        // is eventually reported. Every enable also answers with a report of
        // the applied grid, so no resize can be lost regardless of how this
        // write interleaves with the pending grid application.
        armSizeReports()
    }

    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        beginTextSelection(request)
    }
}

/// `UIResponder.inputView` is read-only by default. A terminal responder that
/// wants an app-specific keyboard redeclares it through a mutable backing view,
/// then asks UIKit to reload the responder's input views when the mode changes.
final class PedalsTerminalView: TerminalView {
    private var replacementInputView: UIView?
    private var preservesFirstResponderDuringSelection = false
    private var hardwareReturnIsPressed = false
    private(set) var wasFirstResponderBeforeCurrentTouch = false
    private weak var focusTouch: UITouch?
    private var focusTouchStartPoint: CGPoint?
    private var focusTouchStartTimestamp: TimeInterval?
    private var focusTouchMaximumMovement: CGFloat = 0
    private var focusTouchIsEligible = false
    private var isTerminalInteractionEnabled = true
    /// KVO tokens watching Ghostty's IOSurface sublayers, keyed by layer
    /// identity. See `syncSurfaceLayerScaleGuards()`.
    private var surfaceLayerScaleGuards: [ObjectIdentifier: NSKeyValueObservation] = [:]
    var softwareKeyboardReturnHandler: (() -> Void)?
    var focusChangeHandler: ((Bool) -> Void)?

    override var inputView: UIView? { replacementInputView }
    override var canBecomeFirstResponder: Bool { isTerminalInteractionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A resize can momentarily leave the IOSurface sublayer larger than
        // the view; never let stale rows bleed outside the terminal area.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncSurfaceLayerScaleGuards()
    }

    // MARK: - IOSurface layer scale ownership

    /// Ghostty's IOSurfaceLayer rewrites its own `contentsScale` when an
    /// asynchronously rendered frame lands after this view has resized (it
    /// stretches the stale frame to fit rather than dropping it). Its
    /// renderer then derives the next frame size from bounds × that adjusted
    /// scale, so one late frame parks the surface in a self-consistently
    /// mis-scaled state — the historic "shrunken canvas" — with no event left
    /// to heal it.
    ///
    /// This view owns the display scale. Observe external writes and answer
    /// each one by re-asserting the native scale and requesting a render
    /// pass, which replaces the stale frame at the correct size.
    private func syncSurfaceLayerScaleGuards() {
        let sublayers = layer.sublayers ?? []
        var seen = Set<ObjectIdentifier>()
        for sublayer in sublayers {
            let id = ObjectIdentifier(sublayer)
            seen.insert(id)
            guard surfaceLayerScaleGuards[id] == nil else { continue }
            surfaceLayerScaleGuards[id] = sublayer.observe(
                \.contentsScale
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.correctExternalSurfaceLayerMutation()
                }
            }
        }
        for id in surfaceLayerScaleGuards.keys where !seen.contains(id) {
            surfaceLayerScaleGuards[id]?.invalidate()
            surfaceLayerScaleGuards.removeValue(forKey: id)
        }
    }

    private func correctExternalSurfaceLayerMutation() {
        let scale = window?.screen.nativeScale
            ?? max(1, traitCollection.displayScale)
        guard let sublayers = layer.sublayers,
              sublayers.contains(where: {
                  $0.contentsScale != scale || $0.frame != bounds
              })
        else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers {
            if sublayer.contentsScale != scale {
                sublayer.contentsScale = scale
            }
            if sublayer.frame != bounds {
                sublayer.frame = bounds
            }
        }
        CATransaction.commit()
        // Redraw so the corrected geometry shows current content instead of
        // the stale frame that triggered the adjustment.
        fitToSize()
    }

    override func insertText(_ text: String) {
        guard isTerminalInteractionEnabled else { return }
        // `ghostty_surface_text` is a text/paste path, not a key path. Even if
        // LF is changed to CR before calling super, a TUI can still receive it
        // as inserted text rather than the terminal Enter key. Route a
        // standalone software-keyboard Return through the same direct CR path
        // as our terminal keyboard instead. Multiline paste stays untouched.
        //
        // Physical keyboards deliver Return through `pressesBegan` first and
        // Ghostty suppresses the matching `insertText` callback. Keep that
        // callback in the superclass path so we do not send Enter twice.
        if TerminalSystemTextInput.shouldSendTerminalEnter(
            text,
            hardwareReturnIsPressed: hardwareReturnIsPressed,
            hasMarkedText: markedTextRange != nil
        ), let softwareKeyboardReturnHandler
        {
            softwareKeyboardReturnHandler()
            return
        }
        super.insertText(TerminalSystemTextInput.normalized(text))
    }

    override func pressesBegan(
        _ presses: Set<UIPress>,
        with event: UIPressesEvent?
    ) {
        guard isTerminalInteractionEnabled else { return }
        if presses.contains(where: Self.isHardwareReturn) {
            hardwareReturnIsPressed = true
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(
        _ presses: Set<UIPress>,
        with event: UIPressesEvent?
    ) {
        guard isTerminalInteractionEnabled else { return }
        super.pressesEnded(presses, with: event)
        if presses.contains(where: Self.isHardwareReturn) {
            hardwareReturnIsPressed = false
        }
    }

    override func pressesCancelled(
        _ presses: Set<UIPress>,
        with event: UIPressesEvent?
    ) {
        guard isTerminalInteractionEnabled else { return }
        super.pressesCancelled(presses, with: event)
        if presses.contains(where: Self.isHardwareReturn) {
            hardwareReturnIsPressed = false
        }
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        guard isTerminalInteractionEnabled else { return false }
        let result = super.becomeFirstResponder()
        if result {
            focusChangeHandler?(true)
        }
        return result
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isTerminalInteractionEnabled else { return }
        guard let touch = touches.first(where: { $0.type == .direct }) else {
            super.touchesBegan(touches, with: event)
            return
        }

        feedPointerPosition(at: touch.location(in: self))

        // Ghostty normally focuses on touch-down, before its pan and long-press
        // recognizers know what the user intended. Defer focus until a short,
        // stationary touch ends so scrolling and selection never summon the
        // keyboard. Gesture recognizers still receive this touch independently.
        wasFirstResponderBeforeCurrentTouch = isFirstResponder
        focusTouch = touch
        focusTouchStartPoint = touch.location(in: self)
        focusTouchStartTimestamp = touch.timestamp
        focusTouchMaximumMovement = 0
        focusTouchIsEligible = event?.allTouches?.filter { $0.type == .direct }.count == 1
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === focusTouch }),
              let startPoint = focusTouchStartPoint
        else {
            if !touches.contains(where: { $0.type == .direct }) {
                super.touchesMoved(touches, with: event)
            }
            return
        }

        let point = touch.location(in: self)
        focusTouchMaximumMovement = max(
            focusTouchMaximumMovement,
            hypot(point.x - startPoint.x, point.y - startPoint.y)
        )
        if focusTouchMaximumMovement > TerminalFocusTapIntent.maximumMovement {
            focusTouchIsEligible = false
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === focusTouch }) else {
            if !touches.contains(where: { $0.type == .direct }) {
                super.touchesEnded(touches, with: event)
            }
            return
        }

        if let startPoint = focusTouchStartPoint,
           let startTimestamp = focusTouchStartTimestamp
        {
            let point = touch.location(in: self)
            let maximumMovement = max(
                focusTouchMaximumMovement,
                hypot(point.x - startPoint.x, point.y - startPoint.y)
            )
            let shouldToggle = focusTouchIsEligible
                && TerminalFocusTapIntent.shouldToggle(
                    duration: touch.timestamp - startTimestamp,
                    maximumMovement: maximumMovement
                )
            resetFocusTouch()

            if shouldToggle {
                if wasFirstResponderBeforeCurrentTouch {
                    resignFirstResponder()
                } else {
                    becomeFirstResponder()
                }
            }
        } else {
            resetFocusTouch()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0 === focusTouch }) {
            resetFocusTouch()
            return
        }
        if !touches.contains(where: { $0.type == .direct }) {
            super.touchesCancelled(touches, with: event)
        }
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        guard !preservesFirstResponderDuringSelection else { return false }
        let result = super.resignFirstResponder()
        if result {
            focusChangeHandler?(false)
        }
        return result
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        syncSurfaceLayerScaleGuards()

        // A deliberate hold should select; even a small scroll should not.
        // Keep Ghostty's recognizer, but tighten its movement tolerance so the
        // vertical pan wins quickly when the finger is actually travelling.
        for case let gesture as UILongPressGestureRecognizer in gestureRecognizers ?? []
        where gesture.delegate === self {
            gesture.minimumPressDuration = 0.58
            gesture.allowableMovement = 7
        }
    }

    func setReplacementInputView(_ inputView: UIView?) {
        replacementInputView = inputView
    }

    func setTerminalInteractionEnabled(_ enabled: Bool) {
        guard isTerminalInteractionEnabled != enabled else { return }
        if !enabled {
            preservesFirstResponderDuringSelection = false
            resetFocusTouch()
        }
        isTerminalInteractionEnabled = enabled
        isUserInteractionEnabled = enabled
        if !enabled, isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    func setPreservesFirstResponderDuringSelection(_ preserves: Bool) {
        preservesFirstResponderDuringSelection = preserves
    }

    func setTouchScrollGestureEnabled(_ enabled: Bool) {
        for case let gesture as UIPanGestureRecognizer in gestureRecognizers ?? []
        where gesture.allowedTouchTypes.contains(
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ) {
            gesture.isEnabled = enabled
        }
    }

    /// Ghostty encodes wheel reports at the last known mouse position, and on
    /// touch devices nothing feeds that position — it stays at the (-1, -1)
    /// sentinel and the core silently drops every wheel event once a TUI
    /// enables mouse reporting. Desktop terminals always have a cursor over
    /// the surface; mirror that by feeding the finger location on touch-down.
    ///
    /// `contextMenuInteraction(_:configurationForMenuAtLocation:)` is the one
    /// public entry point that forwards a position to the emulator. Its menu
    /// side is inert here: the interaction below is never attached to a view,
    /// and the returned configuration (nil without a native Ghostty
    /// selection) is discarded.
    private lazy var pointerPositionInteraction = UIContextMenuInteraction(delegate: self)

    private func feedPointerPosition(at point: CGPoint) {
        _ = contextMenuInteraction(
            pointerPositionInteraction,
            configurationForMenuAtLocation: point
        )
    }

    private func resetFocusTouch() {
        focusTouch = nil
        focusTouchStartPoint = nil
        focusTouchStartTimestamp = nil
        focusTouchMaximumMovement = 0
        focusTouchIsEligible = false
    }

    private static func isHardwareReturn(_ press: UIPress) -> Bool {
        guard let usage = press.key?.keyCode else { return false }
        return usage == .keyboardReturnOrEnter || usage == .keypadEnter
    }
}

/// A terminal focus change is deliberately stricter than UIKit's long-press
/// threshold. Anything slow or mobile belongs to selection/scroll gestures.
enum TerminalFocusTapIntent {
    static let maximumDuration: TimeInterval = 0.3
    static let maximumMovement: CGFloat = 8

    static func shouldToggle(duration: TimeInterval, maximumMovement: CGFloat) -> Bool {
        duration >= 0
            && duration <= maximumDuration
            && maximumMovement <= Self.maximumMovement
    }
}

enum TerminalSystemTextInput {
    static func shouldSendTerminalEnter(
        _ text: String,
        hardwareReturnIsPressed: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !hardwareReturnIsPressed
            && !hasMarkedText
            && (text == "\n" || text == "\r")
    }

    static func normalized(_ text: String) -> String {
        text == "\n" ? "\r" : text
    }
}
