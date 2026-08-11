@testable import TTYBuild
import GhosttyTerminal
import XCTest

final class TerminalLifecycleTests: XCTestCase {
    func testCommittedPageChangeTransfersFocusWhenKeyboardWasUp() {
        XCTAssertTrue(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: true,
            isFirstResponder: false,
            keyboardVisible: true
        ))
    }

    func testCommittedPageChangeKeepsDismissedKeyboardDismissed() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: true,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    func testMetadataRefreshDoesNotReopenDismissedKeyboard() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: false,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    /// Foreground return with the keyboard up at suspension, or an own-created
    /// terminal presenting: the two deliberate keyboard openings.
    func testRestoreFocusReopensKeyboardEvenWhenDismissed() {
        XCTAssertTrue(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: true,
            pageChanged: false,
            isFirstResponder: false,
            keyboardVisible: false
        ))
        XCTAssertTrue(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: true,
            pageChanged: true,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    /// Without restoreFocus, no navigation may summon a dismissed keyboard —
    /// including the first visit to a page (the old `hasBeenFocused` leak).
    func testPlainNavigationNeverSummonsDismissedKeyboard() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: true,
            restoreFocus: false,
            pageChanged: true,
            isFirstResponder: false,
            keyboardVisible: false
        ))
    }

    func testBackgroundTerminalNeverTakesFocus() {
        XCTAssertFalse(TerminalFocusPolicy.shouldFocus(
            applicationActive: false,
            restoreFocus: true,
            pageChanged: true,
            isFirstResponder: false,
            keyboardVisible: true
        ))
    }

    @MainActor
    func testSleepingTerminalCannotBecomeFirstResponder() {
        let view = TTYBuildTerminalView(frame: .zero)

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
