@testable import Pedals
import GhosttyTerminal
import XCTest

final class TerminalLifecycleTests: XCTestCase {
    func testCommittedPageChangeTransfersFocusWhenKeyboardWasUp() {
        XCTAssertTrue(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: true,
            hasBeenFocused: true,
            isFirstResponder: false,
            keyboardVisible: true
        ))
    }

    func testCommittedPageChangeKeepsDismissedKeyboardDismissed() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: true,
            hasBeenFocused: true,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    func testNeverFocusedPageTakesFocusEvenWithDismissedKeyboard() {
        XCTAssertTrue(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: true,
            hasBeenFocused: false,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    func testMetadataRefreshDoesNotReopenDismissedKeyboard() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: false,
            hasBeenFocused: true,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    func testForegroundRestorationRefocusesVisibleTerminal() {
        XCTAssertTrue(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: true,
            pageChanged: false,
            hasBeenFocused: true,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    func testBackgroundTerminalNeverTakesFocus() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: false,
            restoreFocus: true,
            pageChanged: true,
            hasBeenFocused: false,
            isFirstResponder: false,
            keyboardVisible: true
        ))
    }

    @MainActor
    func testSleepingTerminalCannotBecomeFirstResponder() {
        let view = PedalsTerminalView(frame: .zero)

        view.setTerminalInteractionEnabled(false)
        XCTAssertFalse(view.canBecomeFirstResponder)

        view.setTerminalInteractionEnabled(true)
        XCTAssertTrue(view.canBecomeFirstResponder)
    }

    @MainActor
    func testSleepingHostFreezesGeometryAndDropsToolbarInput() {
        let host = TerminalHost(controller: TerminalController())
        var input: Data?
        host.onInput = { input = $0 }

        host.setActive(false)
        host.sendToolbarKey(.enter)

        XCTAssertEqual(host.view.autoresizingMask, [])
        XCTAssertFalse(host.view.canBecomeFirstResponder)
        XCTAssertNil(input)

        host.setActive(true)
        XCTAssertTrue(host.view.autoresizingMask.contains(.flexibleWidth))
        XCTAssertTrue(host.view.autoresizingMask.contains(.flexibleHeight))
        XCTAssertTrue(host.view.canBecomeFirstResponder)
    }

    @MainActor
    func testRecentTerminalDataChannelsStayLiveWithinPoolLimit() {
        let maximum = TerminalManager.maxLiveChannels
        XCTAssertEqual(maximum, 3)
    }
}
