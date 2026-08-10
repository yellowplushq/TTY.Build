import GhosttyTerminal
import UIKit
import XCTest

@testable import TTYBuild

final class TerminalInputKeyTests: XCTestCase {
    func testSystemKeyboardReturnBecomesTerminalEnterWithoutChangingPaste() {
        XCTAssertTrue(TerminalSystemTextInput.shouldSendTerminalEnter(
            "\n",
            hardwareReturnIsPressed: false,
            hasMarkedText: false
        ))
        XCTAssertTrue(TerminalSystemTextInput.shouldSendTerminalEnter(
            "\r",
            hardwareReturnIsPressed: false,
            hasMarkedText: false
        ))
        XCTAssertFalse(TerminalSystemTextInput.shouldSendTerminalEnter(
            "\n",
            hardwareReturnIsPressed: true,
            hasMarkedText: false
        ))
        XCTAssertFalse(TerminalSystemTextInput.shouldSendTerminalEnter(
            "\n",
            hardwareReturnIsPressed: false,
            hasMarkedText: true
        ))
        XCTAssertFalse(TerminalSystemTextInput.shouldSendTerminalEnter(
            "echo one\necho two",
            hardwareReturnIsPressed: false,
            hasMarkedText: false
        ))
        XCTAssertEqual(TerminalSystemTextInput.normalized("\n"), "\r")
        XCTAssertEqual(TerminalSystemTextInput.normalized("\r"), "\r")
        XCTAssertEqual(
            TerminalSystemTextInput.normalized("echo one\necho two"),
            "echo one\necho two"
        )
    }

    func testOnlyShortStationaryTerminalTouchTogglesFocus() {
        XCTAssertTrue(TerminalFocusTapIntent.shouldToggle(
            duration: 0.12,
            maximumMovement: 2
        ))
        XCTAssertFalse(TerminalFocusTapIntent.shouldToggle(
            duration: 0.31,
            maximumMovement: 2
        ))
        XCTAssertFalse(TerminalFocusTapIntent.shouldToggle(
            duration: 0.12,
            maximumMovement: 8.1
        ))
    }

    func testHardwareTextFallbackAppliesControlAndAlt() {
        XCTAssertEqual(
            TerminalKeyModifiers.ctrl.applying(toUnmodifiedByte: UInt8(ascii: "c")),
            Data([0x03])
        )
        XCTAssertEqual(
            TerminalKeyModifiers.alt.applying(toUnmodifiedByte: UInt8(ascii: "x")),
            Data([0x1b, UInt8(ascii: "x")])
        )
        XCTAssertEqual(
            TerminalKeyModifiers.ctrl.union(.alt)
                .applying(toUnmodifiedByte: UInt8(ascii: "[")),
            Data([0x1b, 0x1b])
        )
        XCTAssertEqual(
            TerminalKeyModifiers.shift.applying(toUnmodifiedByte: UInt8(ascii: "a")),
            Data([UInt8(ascii: "A")])
        )
        XCTAssertEqual(
            TerminalKeyModifiers.shift.union(.ctrl)
                .applying(toUnmodifiedByte: UInt8(ascii: "2")),
            Data([0x00])
        )
    }

    func testCursorAndNavigationSequences() {
        XCTAssertEqual(TerminalInputKey.arrow(.up).bytes(), bytes("\u{1b}[A"))
        XCTAssertEqual(
            TerminalInputKey.arrow(.left).bytes(modifiers: [.ctrl]),
            bytes("\u{1b}[1;5D")
        )
        XCTAssertEqual(
            TerminalInputKey.pageDown.bytes(modifiers: [.ctrl, .alt]),
            bytes("\u{1b}[6;7~")
        )
        XCTAssertEqual(TerminalInputKey.home.bytes(), bytes("\u{1b}[H"))
        XCTAssertEqual(TerminalInputKey.end.bytes(), bytes("\u{1b}[F"))
        XCTAssertEqual(TerminalInputKey.shiftTab.bytes(), bytes("\u{1b}[Z"))
        XCTAssertEqual(
            TerminalInputKey.tab.bytes(modifiers: [.shift]),
            bytes("\u{1b}[Z")
        )
        XCTAssertEqual(
            TerminalInputKey.arrow(.right).bytes(
                modifiers: [.shift, .ctrl, .alt, .command]
            ),
            bytes("\u{1b}[1;16C")
        )
    }

    func testShiftedQWERTYCharactersUseUSKeyboardPairs() {
        XCTAssertEqual(TerminalKeyboardText.applyingShift(to: "q"), "Q")
        XCTAssertEqual(TerminalKeyboardText.applyingShift(to: "1"), "!")
        XCTAssertEqual(TerminalKeyboardText.applyingShift(to: "["), "{")
        XCTAssertEqual(TerminalKeyboardText.applyingShift(to: "/"), "?")
        XCTAssertEqual(TerminalKeyboardText.applyingShift(to: " "), " ")
    }

    func testFunctionKeySequences() {
        XCTAssertEqual(TerminalInputKey.function(1).bytes(), bytes("\u{1b}OP"))
        XCTAssertEqual(
            TerminalInputKey.function(4).bytes(modifiers: [.ctrl]),
            bytes("\u{1b}[1;5S")
        )
        XCTAssertEqual(TerminalInputKey.function(5).bytes(), bytes("\u{1b}[15~"))
        XCTAssertEqual(
            TerminalInputKey.function(12).bytes(modifiers: [.alt]),
            bytes("\u{1b}[24;3~")
        )
        XCTAssertNil(TerminalInputKey.function(13).bytes())
    }

    func testEditingAndAppOnlyKeys() {
        XCTAssertEqual(TerminalInputKey.escape.bytes(), Data([0x1b]))
        XCTAssertEqual(TerminalInputKey.enter.bytes(), Data([0x0d]))
        XCTAssertEqual(TerminalInputKey.backspace.bytes(), Data([0x7f]))
        XCTAssertEqual(
            TerminalInputKey.backspace.bytes(modifiers: [.ctrl]),
            Data([0x08])
        )
        XCTAssertEqual(TerminalInputKey.deleteForward.bytes(), bytes("\u{1b}[3~"))
        XCTAssertEqual(TerminalInputKey.clearScreen.bytes(), Data([0x0c]))
        XCTAssertNil(TerminalInputKey.text("|").bytes())
        XCTAssertNil(TerminalInputKey.paste.bytes())
        XCTAssertNil(TerminalInputKey.dismissKeyboard.bytes())
    }

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }
}

@MainActor
final class TerminalInputSurfaceTests: XCTestCase {
    func testCompactToolbarActuallyHasHorizontalOverflow() throws {
        let toolbar = TerminalToolbar(
            frame: CGRect(x: 0, y: 0, width: 344, height: TerminalToolbar.height)
        )
        toolbar.layoutIfNeeded()

        let scroll = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-toolbar-scroll") as? UIScrollView
        )
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
    }

    func testCompactToolbarUsesRequestedKeyOrder() throws {
        let toolbar = TerminalToolbar(
            frame: CGRect(x: 0, y: 0, width: 344, height: TerminalToolbar.height)
        )
        toolbar.layoutIfNeeded()

        let identifiers = [
            "control", "tab", "hyphen", "slash", "shift-tab", "escape",
            "up", "down", "alt", "left", "right",
        ]
        let buttons = try identifiers.map { identifier in
            try XCTUnwrap(
                findSubview(
                    in: toolbar,
                    identifier: "terminal-toolbar-\(identifier)"
                ) as? UIButton
            )
        }

        let xPositions = buttons.map(\.frame.minX)
        XCTAssertEqual(xPositions, xPositions.sorted())
        XCTAssertEqual(
            buttons.compactMap { $0.title(for: .normal) },
            ["CTRL", "TAB", "-", "/", "⇧TAB", "ESC", "ALT"]
        )
    }

    func testCompactToolbarPinsPasteKeyboardAndAnimatedDismissRegion() throws {
        let toolbar = TerminalToolbar(
            frame: CGRect(x: 0, y: 0, width: 390, height: TerminalToolbar.height)
        )
        toolbar.layoutIfNeeded()

        let scroll = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-toolbar-scroll") as? UIScrollView
        )
        let fixedActions = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-toolbar-fixed-actions")
        )
        let paste = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-toolbar-paste") as? UIButton
        )
        let keyboard = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-keyboard-toggle") as? UIButton
        )
        let dismiss = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-toolbar-hide-keyboard") as? UIButton
        )
        fixedActions.superview?.layoutIfNeeded()

        XCTAssertTrue(paste.isDescendant(of: fixedActions))
        XCTAssertTrue(keyboard.isDescendant(of: fixedActions))
        XCTAssertTrue(dismiss.isDescendant(of: fixedActions))
        XCTAssertFalse(paste.isDescendant(of: scroll))
        XCTAssertEqual(dismiss.alpha, 0)
        XCTAssertTrue(dismiss.accessibilityElementsHidden)
        let dismissWidthConstraint = try XCTUnwrap(
            dismiss.constraints.first {
                $0.identifier == "terminal-toolbar-hide-keyboard-width"
            }
        )
        XCTAssertEqual(dismissWidthConstraint.constant, 0)

        var receivedKeys: [TerminalInputKey] = []
        toolbar.onKey = { receivedKeys.append($0) }
        paste.sendActions(for: .touchUpInside)

        toolbar.setKeyboardVisible(true, animated: false)
        fixedActions.superview?.layoutIfNeeded()
        XCTAssertEqual(dismiss.alpha, 1)
        XCTAssertFalse(dismiss.accessibilityElementsHidden)
        XCTAssertEqual(dismissWidthConstraint.constant, 42)
        dismiss.sendActions(for: .touchUpInside)
        XCTAssertEqual(receivedKeys, [.paste, .dismissKeyboard])

        toolbar.setKeyboardVisible(false, animated: false)
        fixedActions.superview?.layoutIfNeeded()
        XCTAssertEqual(dismiss.alpha, 0)
        XCTAssertTrue(dismiss.accessibilityElementsHidden)
        XCTAssertEqual(dismissWidthConstraint.constant, 0)
    }

    func testExpandedKeyboardContainsEssentialKeysOnly() {
        let keyboard = TerminalKeyboardView()
        keyboard.layoutIfNeeded()

        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-f12"))
        XCTAssertNil(findSubview(in: keyboard, identifier: "terminal-key-hide-keyboard"))
        XCTAssertNil(findSubview(in: keyboard, identifier: "terminal-key-paste"))
        XCTAssertNil(findSubview(in: keyboard, identifier: "terminal-key-shift-tab"))
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-command"))
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-option"))
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-tab"))
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-q"))
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-keyboard-fixed-footer"))
        let pageControl = findSubview(
            in: keyboard,
            identifier: "terminal-keyboard-page-control"
        ) as? UIPageControl
        XCTAssertEqual(pageControl?.numberOfPages, 2)
        XCTAssertEqual(pageControl?.currentPage, 0)
        XCTAssertGreaterThan(keyboard.intrinsicContentSize.height, 0)
    }

    func testExpandedKeyboardUsesInteractiveHorizontalPagingGesture() throws {
        let keyboard = TerminalKeyboardView()
        keyboard.frame = CGRect(
            x: 0, y: 0, width: 402,
            height: keyboard.intrinsicContentSize.height
        )
        keyboard.layoutIfNeeded()
        let pageContainer = try XCTUnwrap(
            findSubview(
                in: keyboard,
                identifier: "terminal-keyboard-page-container"
            ) as? UIScrollView
        )

        XCTAssertTrue(pageContainer.isPagingEnabled)
        XCTAssertFalse(pageContainer.bounces)
        XCTAssertTrue(pageContainer.delegate === keyboard)
        XCTAssertFalse(pageContainer.isScrollEnabled)
        let pagePan = try XCTUnwrap(
            pageContainer.gestureRecognizers?.first {
                $0.name == "terminal-keyboard-page-pan"
            } as? UIPanGestureRecognizer
        )
        XCTAssertEqual(pagePan.minimumNumberOfTouches, 1)
        XCTAssertEqual(pagePan.maximumNumberOfTouches, 1)
        XCTAssertEqual(
            pageContainer.contentSize.width,
            pageContainer.bounds.width * 2 + 12,
            accuracy: 0.5
        )
        XCTAssertEqual(
            pageContainer.contentOffset.x,
            0,
            accuracy: 0.5
        )
        keyboard.showQWERTYPage(animated: false)
        XCTAssertEqual(
            pageContainer.contentOffset.x,
            pageContainer.bounds.width + 12,
            accuracy: 0.5
        )
        XCTAssertFalse(
            pageContainer.gestureRecognizers?.contains { $0 is UISwipeGestureRecognizer } ?? true
        )
    }

    func testTabStaysOnKeyboardPageInsteadOfModifierFooter() throws {
        let keyboard = TerminalKeyboardView()
        let footer = try XCTUnwrap(
            findSubview(in: keyboard, identifier: "terminal-keyboard-fixed-footer")
        )
        let tab = try XCTUnwrap(
            findSubview(in: keyboard, identifier: "terminal-key-tab")
        )

        XCTAssertFalse(tab.isDescendant(of: footer))
        for identifier in ["shift", "control", "option", "command"] {
            let modifier = try XCTUnwrap(
                findSubview(in: keyboard, identifier: "terminal-key-\(identifier)")
            )
            XCTAssertTrue(modifier.isDescendant(of: footer))
        }
    }

    func testExpandedKeyboardKeepsOneShotModifiersVisibleAcrossPages() throws {
        let keyboard = TerminalKeyboardView()
        keyboard.setModifierState(TerminalModifierState(
            shift: true, ctrl: true, alt: true, command: true
        ))

        for identifier in ["shift", "control", "option", "command"] {
            let button = try XCTUnwrap(
                findSubview(in: keyboard, identifier: "terminal-key-\(identifier)") as? UIButton
            )
            XCTAssertTrue(button.isSelected)
            XCTAssertEqual(button.layer.borderWidth, 1)
        }

        let q = try XCTUnwrap(
            findSubview(in: keyboard, identifier: "terminal-key-q") as? UIButton
        )
        XCTAssertEqual(q.title(for: .normal), "Q")

        keyboard.showQWERTYPage(animated: false)
        let pageControl = try XCTUnwrap(
            findSubview(
                in: keyboard,
                identifier: "terminal-keyboard-page-control"
            ) as? UIPageControl
        )
        XCTAssertEqual(pageControl.currentPage, 1)
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-tab"))
    }

    func testExpandedKeyboardVisualLayout() {
        let keyboard = TerminalKeyboardView()
        keyboard.frame = CGRect(
            x: 0, y: 0, width: 402,
            height: keyboard.intrinsicContentSize.height
        )
        keyboard.layoutIfNeeded()
        attachSnapshot(of: keyboard, named: "terminal-keyboard")

        keyboard.showQWERTYPage(animated: false)
        keyboard.layoutIfNeeded()
        attachSnapshot(of: keyboard, named: "qwerty-keyboard")
    }

    func testTerminalViewRoutesSoftwareReturnThroughDirectHandler() {
        let view = TTYBuildTerminalView(frame: .zero)
        var returnCount = 0
        view.softwareKeyboardReturnHandler = { returnCount += 1 }

        view.insertText("\n")
        view.insertText("\r")
        view.insertText("echo one\necho two")

        XCTAssertEqual(returnCount, 2)
    }

    func testTerminalHostConsumesCompleteModifierChordAfterOneKey() {
        let host = TerminalHost(controller: TerminalController())
        var input: Data?
        host.onInput = { input = $0 }

        host.toggleModifier(.shift)
        host.toggleModifier(.ctrl)
        host.toggleModifier(.alt)
        host.toggleModifier(.command)
        XCTAssertEqual(
            host.modifierState,
            TerminalModifierState(shift: true, ctrl: true, alt: true, command: true)
        )

        host.sendToolbarKey(.arrow(.right))

        XCTAssertEqual(input, Data("\u{1b}[1;16C".utf8))
        XCTAssertEqual(host.modifierState, TerminalModifierState())
    }

    func testTappingArmedModifierAgainCancelsInsteadOfLocking() {
        let host = TerminalHost(controller: TerminalController())

        host.toggleModifier(.command)
        XCTAssertTrue(host.modifierState.command)
        host.toggleModifier(.command)
        XCTAssertFalse(host.modifierState.command)
    }

    private func findSubview(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let match = findSubview(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    private func attachSnapshot(of view: UIView, named name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
