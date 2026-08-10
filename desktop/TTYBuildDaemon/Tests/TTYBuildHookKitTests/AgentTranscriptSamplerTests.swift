import Foundation
import XCTest

@testable import TTYBuildHookKit

final class AgentTranscriptSamplerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-sampler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func write(
        _ lines: [[String: Any]], agentDirectory: String
    ) throws -> URL {
        let directory = home.appendingPathComponent(agentDirectory, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("sample.jsonl")
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    func testClaudeLatestAgentMessageIgnoresTools() throws {
        let textURL = try write([
            [
                "type": "assistant",
                "message": ["content": [
                    ["type": "tool_use", "name": "Read", "input": ["file_path": "/p/A.swift"]],
                ]],
            ],
            [
                "type": "assistant",
                "message": ["content": [
                    ["type": "text", "text": "Found the race and preparing the fix."],
                ]],
            ],
        ], agentDirectory: ".claude")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "claude", path: textURL.path, environment: [:], home: home
            ),
            .init(detail: "Found the race and preparing the fix.")
        )

        let actionURL = try write([
            [
                "type": "assistant",
                "message": ["content": [
                    ["type": "text", "text": "Running verification."],
                    [
                        "type": "tool_use", "name": "Bash",
                        "input": ["command": "swift test\nswift build"],
                    ],
                ]],
            ],
        ], agentDirectory: ".claude")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "claude", path: actionURL.path, environment: [:], home: home
            ),
            .init(detail: "Running verification.")
        )

        let bareToolURL = try write([
            [
                "type": "assistant",
                "message": ["content": [
                    ["type": "text", "text": "I found the relevant files."],
                ]],
            ],
            [
                "type": "assistant",
                "message": ["content": [
                    ["type": "tool_use", "name": "Glob", "input": [:]],
                ]],
            ],
        ], agentDirectory: ".claude")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "claude", path: bareToolURL.path, environment: [:], home: home
            ),
            .init(detail: "I found the relevant files.")
        )

        let multipartURL = try write([
            [
                "type": "assistant",
                "message": ["content": [
                    ["type": "text", "text": "Found the issue. "],
                    ["type": "text", "text": "Applying the fix now."],
                ]],
            ],
        ], agentDirectory: ".claude")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "claude", path: multipartURL.path, environment: [:], home: home
            ),
            .init(detail: "Found the issue. Applying the fix now.")
        )
    }

    func testClaudeSessionTitlePickedUpAlongsideMessage() throws {
        let url = try write([
            ["type": "ai-title", "aiTitle": "Investigate push status"],
            [
                "type": "assistant",
                "message": ["content": [["type": "text", "text": "On it."]]],
            ],
        ], agentDirectory: ".claude")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "claude", path: url.path, environment: [:], home: home
            ),
            .init(detail: "On it.", sessionTitle: "Investigate push status")
        )
    }

    func testClaudeTitleOnlyTranscriptStillReturnsActivity() throws {
        let url = try write([
            ["type": "custom-title", "customTitle": "Release prep"],
        ], agentDirectory: ".claude")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "claude", path: url.path, environment: [:], home: home
            ),
            .init(detail: nil, sessionTitle: "Release prep")
        )
    }

    func testCodexLatestAgentMessageIgnoresTools() throws {
        let messageURL = try write([
            [
                "type": "response_item",
                "payload": [
                    "type": "function_call", "name": "exec_command",
                    "arguments": #"{"cmd":"swift test"}"#,
                ],
            ],
            [
                "type": "event_msg",
                "payload": [
                    "type": "agent_message",
                    "message": "Tests passed; validating the archive now.",
                ],
            ],
        ], agentDirectory: ".codex")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "codex", path: messageURL.path, environment: [:], home: home
            ),
            .init(detail: "Tests passed; validating the archive now.")
        )

        let actionURL = try write([
            [
                "type": "response_item",
                "payload": [
                    "type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": "Checking the project."]],
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "custom_tool_call", "name": "apply_patch",
                    "input": "*** Begin Patch\n*** Update File: App.swift",
                ],
            ],
        ], agentDirectory: ".codex")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "codex", path: actionURL.path, environment: [:], home: home
            ),
            .init(detail: "Checking the project.")
        )

        let multipartURL = try write([
            [
                "type": "response_item",
                "payload": [
                    "type": "message", "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "Tests passed. "],
                        ["type": "output_text", "text": "Preparing the release."],
                    ],
                ],
            ],
        ], agentDirectory: ".codex")
        XCTAssertEqual(
            AgentTranscriptSampler.latestActivity(
                agent: "codex", path: multipartURL.path, environment: [:], home: home
            ),
            .init(detail: "Tests passed. Preparing the release.")
        )
    }

    func testPathMustStayInsideAgentRootAfterResolvingSymlinks() throws {
        let outside = home.appendingPathComponent("outside.jsonl")
        try Data("{}\n".utf8).write(to: outside)
        XCTAssertFalse(AgentTranscriptSampler.isAllowedPath(
            agent: "claude", path: outside.path, environment: [:], home: home
        ))

        let directory = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let link = directory.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(AgentTranscriptSampler.isAllowedPath(
            agent: "claude", path: link.path, environment: [:], home: home
        ))
        XCTAssertFalse(AgentTranscriptSampler.isAllowedPath(
            agent: "other", path: link.path, environment: [:], home: home
        ))
    }
}
