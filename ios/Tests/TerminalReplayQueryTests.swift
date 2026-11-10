@testable import TTYBuild
import XCTest

/// Query replies around a replay snapshot. Replayed history re-asks queries
/// that were answered long ago, so those replies must stay off the PTY; but a
/// shell can still be blocked on a query at the end of the snapshot (fish 4.x
/// waits for its startup Primary Device Attributes reply), and that one must
/// be answered or the session never reaches a prompt.
@MainActor
final class TerminalReplayQueryTests: XCTestCase {
    /// fish 4.9 startup output up to the point where it blocks on DA1, as
    /// captured from a real PTY (with a config.fish line printing first).
    private static let fishStartup = Data(
        ("CapLockDelayOverride:0\r\n\u{1b}[?u\u{1b}[>0q\u{1b}]11;?\u{1b}\\"
            + "\u{1b}[?1049h\u{1b}P+q696e646e\u{1b}\\"
            + "\u{1b}P+q71756572792d6f732d6e616d65\u{1b}\\"
            + "\u{1b}[?1049l\u{1b}[0c").utf8
    )

    private var terminal: AttachedTerminalHost?

    override func tearDown() {
        terminal?.tearDown()
        terminal = nil
        super.tearDown()
    }

    /// Control: the attached emulator answers DA1 at all, so a missing reply
    /// in the tests below is the host's filtering, not the harness.
    func testLiveQueryWithoutReplayIsAnswered() {
        let terminal = makeTerminal()

        terminal.host.feed(Data("\u{1b}[0c".utf8))

        XCTAssertTrue(AttachedTerminalHost.waitUntil { terminal.containsDeviceAttributesReply })
    }

    func testReplayEndingInUnansweredQueryIsAnswered() {
        let terminal = makeTerminal()

        terminal.host.feedReplay(Self.fishStartup)

        XCTAssertTrue(
            AttachedTerminalHost.waitUntil { terminal.containsDeviceAttributesReply },
            "fish stays blocked forever without a DA1 reply"
        )
    }

    func testLiveQueryRightAfterReplayIsAnswered() {
        let terminal = makeTerminal()

        terminal.host.feedReplay(Data("prompt> ".utf8))
        terminal.host.feed(Data("\u{1b}[0c".utf8))

        XCTAssertTrue(AttachedTerminalHost.waitUntil { terminal.containsDeviceAttributesReply })
    }

    func testQueryAnsweredEarlierInHistoryIsNotReanswered() {
        let terminal = makeTerminal()

        terminal.host.feedReplay(Data("\u{1b}[0cWelcome\r\nprompt> ".utf8))

        XCTAssertFalse(AttachedTerminalHost.waitUntil(timeout: 1) {
            terminal.containsDeviceAttributesReply
        })
    }

    private func makeTerminal() -> AttachedTerminalHost {
        let terminal = AttachedTerminalHost()
        self.terminal = terminal
        return terminal
    }
}
