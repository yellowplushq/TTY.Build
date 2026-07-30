import XCTest
@testable import PedalsKit

final class AgentActivityPresentationTests: XCTestCase {
    func testSessionNameIsTitleAndLatestMessageIsDetail() {
        let info = AgentInfo(
            id: "a-1",
            agent: "codex",
            state: .done,
            sessionName: "  Ship Pedals  ",
            cwd: "/tmp/pedals",
            message: "  The new client is ready.  ",
            prompt: "This prompt must never become the title",
            updatedAt: 1
        )

        let presentation = AgentActivity.Presentation(info: info)
        XCTAssertEqual(presentation.title, "Ship Pedals")
        XCTAssertEqual(presentation.detail, "The new client is ready.")
    }

    func testRunningAlwaysPrefersLastAgentMessageOverToolAction() {
        let info = AgentInfo(
            id: "a-1",
            agent: "claude",
            state: .running,
            sessionName: "Agent monitoring",
            cwd: "/tmp/pedals",
            action: "Build: PedalsWidgets",
            message: "Previous turn completed",
            updatedAt: 1
        )

        XCTAssertEqual(
            AgentActivity.Presentation(info: info).detail,
            "Previous turn completed"
        )
    }

    func testRunningFallsBackToLatestUserPrompt() {
        let info = AgentInfo(
            id: "a-1", agent: "codex", state: .running,
            sessionName: "Agent monitoring", cwd: "/tmp/pedals",
            prompt: "Make the Dynamic Island show the latest agent",
            updatedAt: 1
        )

        XCTAssertEqual(
            AgentActivity.Presentation(info: info).detail,
            "Make the Dynamic Island show the latest agent"
        )
    }

    func testUnmanagedSessionFallsBackToProjectThenAgentName() {
        let project = AgentInfo(
            id: "a-1", agent: "claude", state: .waiting,
            cwd: "/Users/me/Projects/pedals", updatedAt: 1
        )
        XCTAssertEqual(AgentActivity.Presentation(info: project).title, "pedals")

        let unknown = AgentInfo(
            id: "a-2", agent: "codex", state: .running,
            cwd: "", updatedAt: 1
        )
        XCTAssertEqual(AgentActivity.Presentation(info: unknown).title, "Codex")
    }

    func testManagedSurfaceCanSupplyItsLiveSessionTitle() {
        let info = AgentInfo(
            id: "a-1", agent: "claude", state: .waiting,
            cwd: "/tmp/pedals", message: "Pick a plan", updatedAt: 1
        )

        let presentation = AgentActivity.Presentation(
            info: info, fallbackSessionName: "Claude — release"
        )
        XCTAssertEqual(presentation.title, "Claude — release")
        XCTAssertEqual(presentation.detail, "Pick a plan")
    }
}
