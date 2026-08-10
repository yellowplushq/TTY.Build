import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let model: AppModel
    private let updater: UpdaterModel
    private let permissions: PermissionsModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let contextMenu = NSMenu()
    private let capsuleLayer = CALayer()
    private weak var updateMenuItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []
    private var lengthAnimationTimer: Timer?
    private var lengthAnimationStart: CGFloat = 0
    private var lengthAnimationTarget: CGFloat = 0
    private var lengthAnimationStartedAt: TimeInterval = 0
    private var lengthAnimationCompletion: (@MainActor () -> Void)?
    private var displayedSessionCount = 0

    private var compactLength: CGFloat {
        NSStatusBar.system.thickness
    }

    init(model: AppModel, updater: UpdaterModel, permissions: PermissionsModel) {
        self.model = model
        self.updater = updater
        self.permissions = permissions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusItem()
        configurePopover()
        configureContextMenu()
        observeSessions()

        #if DEBUG
        if ProcessInfo.processInfo.environment["TTYBUILD_SHOW_POPOVER_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = statusItem.button else { return }
                togglePopover(relativeTo: button)
            }
        }
        #endif
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        statusItem.length = compactLength
        button.image = NSImage(named: "StatusBarIcon")
        button.image?.accessibilityDescription = "TTY.Build"
        button.image?.size = NSSize(width: 18, height: 18)
        button.image?.isTemplate = true
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.wantsLayer = true

        capsuleLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        capsuleLayer.cornerCurve = .continuous
        capsuleLayer.opacity = 0
        capsuleLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        button.layer?.insertSublayer(capsuleLayer, at: 0)
        updateCapsuleFrame(for: button)

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func observeSessions() {
        model.$sessions
            .map { sessions in sessions.lazy.filter(\.alive).count }
            .removeDuplicates()
            .sink { [weak self] count in
                self?.setSessionCount(count, animated: true)
            }
            .store(in: &cancellables)
    }

    private func setSessionCount(_ count: Int, animated: Bool) {
        guard let button = statusItem.button else { return }
        let count = max(0, count)
        let isExpanded = count > 0
        displayedSessionCount = count

        if isExpanded {
            button.title = "\(count)"
            button.imagePosition = .imageLeading
            button.toolTip = count == 1 ? "1 active terminal" : "\(count) active terminals"
            button.setAccessibilityLabel(button.toolTip)
        } else {
            button.toolTip = "TTY.Build"
            button.setAccessibilityLabel("TTY.Build")
        }

        let targetLength = isExpanded ? expandedLength(for: count, button: button) : compactLength
        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        setCapsuleVisible(isExpanded, animated: shouldAnimate)
        animateLength(to: targetLength, animated: shouldAnimate) { [weak self, weak button] in
            guard let self, let button, displayedSessionCount == 0 else { return }
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func expandedLength(for count: Int, button: NSStatusBarButton) -> CGFloat {
        let font = button.font ?? .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let countWidth = ("\(count)" as NSString).size(withAttributes: [.font: font]).width
        return max(46, ceil(18 + 5 + countWidth + 14))
    }

    private func setCapsuleVisible(_ visible: Bool, animated: Bool) {
        let targetOpacity: Float = visible ? 1 : 0
        capsuleLayer.removeAnimation(forKey: "opacity")

        guard animated else {
            capsuleLayer.opacity = targetOpacity
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = capsuleLayer.presentation()?.opacity ?? capsuleLayer.opacity
        animation.toValue = targetOpacity
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        capsuleLayer.opacity = targetOpacity
        capsuleLayer.add(animation, forKey: "opacity")
    }

    private func animateLength(
        to targetLength: CGFloat,
        animated: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        lengthAnimationTimer?.invalidate()
        lengthAnimationTimer = nil
        lengthAnimationCompletion = nil

        let startLength = statusItem.length > 0 ? statusItem.length : compactLength
        guard animated, abs(targetLength - startLength) > 0.5 else {
            statusItem.length = targetLength
            if let button = statusItem.button {
                updateCapsuleFrame(for: button)
            }
            completion()
            return
        }

        lengthAnimationStart = startLength
        lengthAnimationTarget = targetLength
        lengthAnimationStartedAt = ProcessInfo.processInfo.systemUptime
        lengthAnimationCompletion = completion

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(stepLengthAnimation(_:)),
            userInfo: nil,
            repeats: true
        )
        lengthAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func stepLengthAnimation(_ timer: Timer) {
        let duration = 0.26
        let elapsed = ProcessInfo.processInfo.systemUptime - lengthAnimationStartedAt
        let progress = min(1, elapsed / duration)
        let eased = progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - pow(-2 * progress + 2, 3) / 2

        statusItem.length = lengthAnimationStart
            + (lengthAnimationTarget - lengthAnimationStart) * eased
        if let button = statusItem.button {
            updateCapsuleFrame(for: button)
        }

        guard progress >= 1 else { return }
        timer.invalidate()
        lengthAnimationTimer = nil
        statusItem.length = lengthAnimationTarget
        let completion = lengthAnimationCompletion
        lengthAnimationCompletion = nil
        completion?()
    }

    private func updateCapsuleFrame(for button: NSStatusBarButton) {
        let frame = button.bounds.insetBy(dx: 1, dy: 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capsuleLayer.frame = frame
        capsuleLayer.cornerRadius = frame.height / 2
        CATransaction.commit()
    }

    private func configurePopover() {
        let root = MenuView()
            .environmentObject(model)
            .environmentObject(updater)
            .environmentObject(permissions)
        let hostingController = NSHostingController(rootView: root)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = hostingController
    }

    private func configureContextMenu() {
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false

        let update = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        update.target = self
        contextMenu.addItem(update)
        updateMenuItem = update

        contextMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit TTY.Build",
            action: #selector(quitTTYBuild),
            keyEquivalent: "q"
        )
        quit.target = self
        contextMenu.addItem(quit)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            contextMenu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 2),
                in: sender
            )
        } else {
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuItem?.isEnabled = updater.canCheckForUpdates
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func quitTTYBuild() {
        NSApplication.shared.terminate(nil)
    }
}
