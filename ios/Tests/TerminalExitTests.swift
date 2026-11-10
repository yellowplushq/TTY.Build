@testable import TTYBuild
import XCTest

@MainActor
final class TerminalExitTests: XCTestCase {
    private var terminal: AttachedTerminalHost?

    override func tearDown() {
        terminal?.tearDown()
        terminal = nil
        super.tearDown()
    }

    func testOnlyCleanExitClosesTab() {
        XCTAssertTrue(TerminalExitPolicy.closesTab(exitCode: 0))
        XCTAssertFalse(TerminalExitPolicy.closesTab(exitCode: 1))
        XCTAssertFalse(TerminalExitPolicy.closesTab(exitCode: 143))
    }

    /// Ghostty treats a short-lived non-zero exit as a failed launch. A
    /// session that ran for a minute must read as an ordinary exit.
    func testLongRunningFailureIsNotReportedAsFailedLaunch() {
        let terminal = makeTerminal()

        terminal.host.markExited(code: 1, runtime: 60)

        XCTAssertTrue(AttachedTerminalHost.waitUntil {
            terminal.host.viewportText?.contains("Process exited") == true
        }, terminal.host.viewportText ?? "no viewport text")
        XCTAssertFalse(terminal.host.viewportText?.contains("failed to launch") == true)
    }

    /// A failed session stays on screen until the user dismisses it; Ghostty
    /// closes surfaces on exit by default.
    func testFailedExitStaysOpenWithoutInput() {
        let terminal = makeTerminal()
        var closeRequests = 0
        terminal.host.onCloseRequest = { closeRequests += 1 }

        terminal.host.markExited(code: 143, runtime: 60)

        XCTAssertFalse(AttachedTerminalHost.waitUntil(timeout: 1) { closeRequests > 0 })
        XCTAssertTrue(terminal.host.viewportText?.contains("Process exited") == true)
    }

    /// The software keyboard reaches Ghostty as text, which Ghostty's own
    /// "press any key to close" never sees.
    func testTypingOnExitedSessionRequestsClose() {
        let terminal = makeTerminal()
        var closeRequests = 0
        terminal.host.onCloseRequest = { closeRequests += 1 }

        terminal.host.markExited(code: 1, runtime: 60)
        terminal.host.view.insertText("q")

        XCTAssertTrue(AttachedTerminalHost.waitUntil { closeRequests > 0 })
        XCTAssertTrue(terminal.inputs.isEmpty, "a dead session must not get stdin")
    }

    func testToolbarKeyOnExitedSessionRequestsClose() {
        let terminal = makeTerminal()
        var closeRequests = 0
        terminal.host.onCloseRequest = { closeRequests += 1 }

        terminal.host.markExited(code: 1, runtime: 60)
        terminal.host.sendToolbarKey(.enter)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertTrue(terminal.inputs.isEmpty)
    }

    func testTypingOnLiveSessionDoesNotClose() {
        let terminal = makeTerminal()
        var closeRequests = 0
        terminal.host.onCloseRequest = { closeRequests += 1 }

        terminal.host.sendToolbarKey(.enter)

        XCTAssertEqual(closeRequests, 0)
        XCTAssertFalse(terminal.inputs.isEmpty)
    }

    func testLiveProcessIsNeverClosedFromTheEmulator() {
        let terminal = makeTerminal()
        var closeRequests = 0
        terminal.host.onCloseRequest = { closeRequests += 1 }

        terminal.host.terminalDidClose(processAlive: true)

        XCTAssertEqual(closeRequests, 0)
    }

    private func makeTerminal() -> AttachedTerminalHost {
        let terminal = AttachedTerminalHost()
        self.terminal = terminal
        return terminal
    }
}
