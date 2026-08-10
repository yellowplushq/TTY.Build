import TTYBuildKit
import UIKit
import XCTest

@testable import TTYBuild

@MainActor
final class TabStripViewTests: XCTestCase {
    func testTwoUnfocusedTabsExpandFinalTabAcrossAvailableWidth() throws {
        let strip = makeStrip(activeID: nil)
        let scrollView = try XCTUnwrap(strip.subviews.compactMap { $0 as? UIScrollView }.first)
        let pills = scrollView.subviews.compactMap { $0 as? TabPillView }
            .sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertEqual(pills.count, 2)
        XCTAssertLessThan(pills[0].frame.width, pills[1].frame.width)
        XCTAssertEqual(pills[0].frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(pills[1].frame.maxX, scrollView.bounds.width, accuracy: 0.5)
    }

    func testTerminalAndAgentTabsAlwaysCarryIconsAndAgentBadgeMatchesHome() throws {
        let strip = makeStrip(activeID: id(2), agentState: .waiting)
        let scrollView = try XCTUnwrap(strip.subviews.compactMap { $0 as? UIScrollView }.first)
        let pills = scrollView.subviews.compactMap { $0 as? TabPillView }
            .sorted { $0.frame.minX < $1.frame.minX }

        XCTAssertEqual(pills.count, 2)
        for pill in pills {
            let icon = try XCTUnwrap(
                descendant(in: pill, accessibilityIdentifier: "ttybuild.tab.icon") as? UIImageView
            )
            XCTAssertNotNil(icon.image)
        }

        let waitingBadge = try XCTUnwrap(
            descendant(
                in: pills[1],
                accessibilityIdentifier: "ttybuild.tab.agent-state-badge"
            )
        )
        XCTAssertFalse(waitingBadge.isHidden)

        strip.update(
            tabs: tabs(agentState: .done),
            activeId: id(2)
        )
        strip.layoutIfNeeded()
        XCTAssertTrue(waitingBadge.isHidden)
    }

    func testClosingLastTabSelectsItsPredecessor() {
        let terminals = (1 ... 3).map { sid in
            Terminal(
                id: id(sid),
                info: SessionInfo(
                    id: sid,
                    title: "Tab \(sid)",
                    cwd: "/tmp",
                    rows: 24,
                    cols: 80,
                    createdAt: 0,
                    alive: true
                ),
                computerName: "Mac"
            )
        }

        XCTAssertEqual(
            TerminalManager.replacementID(afterClosing: id(3), in: terminals),
            id(2)
        )
        XCTAssertEqual(
            TerminalManager.replacementID(afterClosing: id(2), in: terminals),
            id(1)
        )
        XCTAssertEqual(
            TerminalManager.replacementID(afterClosing: id(1), in: terminals),
            id(2)
        )
        XCTAssertNil(
            TerminalManager.replacementID(afterClosing: id(1), in: [terminals[0]])
        )
    }

    private func makeStrip(
        activeID: TerminalID?,
        agentState: AgentState = .running
    ) -> TabStripView {
        let strip = TabStripView(frame: CGRect(x: 0, y: 0, width: 393, height: 44))
        strip.update(tabs: tabs(agentState: agentState), activeId: activeID)
        strip.layoutIfNeeded()
        return strip
    }

    private func tabs(agentState: AgentState) -> [TabStripView.Tab] {
        [
            .init(
                id: id(1),
                title: "Terminal",
                alive: true,
                agent: nil,
                agentState: nil
            ),
            .init(
                id: id(2),
                title: "Agent",
                alive: true,
                agent: "codex",
                agentState: agentState
            ),
        ]
    }

    private func descendant(
        in root: UIView,
        accessibilityIdentifier: String
    ) -> UIView? {
        if root.accessibilityIdentifier == accessibilityIdentifier {
            return root
        }
        for subview in root.subviews {
            if let match = descendant(
                in: subview,
                accessibilityIdentifier: accessibilityIdentifier
            ) {
                return match
            }
        }
        return nil
    }

    private func id(_ sid: Int) -> TerminalID {
        TerminalID(computerID: "computer", sid: sid)
    }
}
