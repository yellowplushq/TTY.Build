import Darwin
import Foundation
import TTYBuildHookKit
import TTYBuildKit
import XCTest

@testable import TTYBuildDaemonCore

/// AgentMonitor state machine, ownership dedup, liveness, and debounce.
final class AgentMonitorTests: XCTestCase {
    /// Mutable match-target source standing in for the SessionManager.
    private final class Targets: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [SessionManager.AgentMatchTarget] = []
        var current: [SessionManager.AgentMatchTarget] {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private var targets: Targets!
    private var monitor: AgentMonitor!

    override func setUp() {
        targets = Targets()
        var tuning = AgentMonitor.Tuning()
        tuning.debounce = 0.08
        // Long enough that the periodic sweep never interferes with tests,
        // which drive sweeps explicitly via `sweepNow()`.
        tuning.sweepInterval = 3600
        tuning.doneAttentionDelay = 0.1
        // Most tests assert the state machine itself, with edges visible
        // immediately; the confirmation window has its own tests below,
        // which rebuild the monitor with a real window.
        tuning.stateConfirmationWindow = 0
        // A neutral resolver keeps tests hermetic: the default one reads the
        // real ~/.codex state database, which would filter test sessions as
        // ephemeral threads on a machine with Codex installed.
        monitor = AgentMonitor(
            tuning: tuning,
            codexMetadataResolver: { _ in .init() },
            matchTargets: { [targets] in targets!.current }
        )
    }

    /// Sleeps past the test's done hold-back window (0.1s) so a held done
    /// push either lands or is proven cancelled.
    private func waitPastDoneDelay() {
        let expectation = expectation(description: "done hold-back elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    /// A live pid: our own test process, so kill(pid, 0) always succeeds.
    private var livePid: Int32 { getpid() }

    private func event(
        _ event: String, id: String = "a-1", cwd: String? = "/tmp/p",
        agent: String = "claude",
        sessionName: String? = nil,
        prompt: String? = nil, message: String? = nil, action: String? = nil,
        transcriptPath: String? = nil,
        agentError: Bool? = nil,
        notifyKind: String? = nil,
        seq: UInt64? = nil, agentPid: Int32? = nil,
        lineage: [AgentLineageEntry]? = nil
    ) -> AgentEvent {
        AgentEvent(
            agent: agent, event: event, agentSessionId: id,
            sessionName: sessionName, cwd: cwd,
            prompt: prompt, message: message, action: action,
            transcriptPath: transcriptPath,
            agentError: agentError,
            notifyKind: notifyKind,
            seq: seq, agentPid: agentPid,
            lineage: lineage ?? [AgentLineageEntry(pid: livePid, name: "claude")]
        )
    }

    private func only() throws -> AgentInfo {
        let list = monitor.list()
        XCTAssertEqual(list.count, 1)
        return try XCTUnwrap(list.first)
    }

    // MARK: - State machine

    func testStateMachineTransitions() throws {
        monitor.ingest(event("session-start"))
        XCTAssertEqual(try only().state, .running)

        monitor.ingest(event("prompt", prompt: "fix the tests"))
        var info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.prompt, "fix the tests")

        monitor.ingest(event("tool", action: "Bash: swift test"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.action, "Bash: swift test")

        monitor.ingest(event("ask"))
        info = try only()
        XCTAssertEqual(info.state, .waiting)
        XCTAssertEqual(info.message, "Waiting for your answer")

        monitor.ingest(event("notify", message: "Permission needed"))
        info = try only()
        XCTAssertEqual(info.state, .waiting)
        XCTAssertEqual(info.message, "Permission needed")

        monitor.ingest(event("compact"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.action, "Compacting context")

        monitor.ingest(event("stop", message: "All done."))
        info = try only()
        XCTAssertEqual(info.state, .done)
        XCTAssertEqual(info.message, "All done.")

        monitor.ingest(event("session-end"))
        XCTAssertTrue(monitor.list().isEmpty)
    }

    func testNewestUserOrAgentMessageWinsAcrossTurns() throws {
        monitor.ingest(event("tool", action: "Bash: ls"))
        monitor.ingest(event("notify", message: "hello"))
        monitor.ingest(event("prompt", prompt: "next"))
        var info = try only()
        XCTAssertNil(info.action)
        XCTAssertNil(info.message, "the new prompt supersedes the previous agent message")
        XCTAssertEqual(info.prompt, "next")
        XCTAssertEqual(AgentActivity.Presentation(info: info).detail, "next")

        monitor.ingest(event("tool", message: "On it."))
        info = try only()
        XCTAssertEqual(info.message, "On it.")
        XCTAssertEqual(
            AgentActivity.Presentation(info: info).detail,
            "On it.",
            "a later agent message supersedes the user prompt"
        )

        monitor.ingest(event("prompt"))
        XCTAssertEqual(
            try only().message,
            "On it.",
            "a textless turn-start does not erase the last displayable message"
        )
    }

    func testCodexFirstPromptBecomesStableFallbackSessionTitle() throws {
        monitor.ingest(event(
            "prompt", agent: "codex",
            prompt: "  Fix the agent titles\nand useful descriptions  "
        ))
        XCTAssertEqual(
            try only().sessionName,
            "Fix the agent titles and useful descriptions"
        )

        monitor.ingest(event(
            "prompt", agent: "codex", prompt: "Now publish TestFlight"
        ))
        XCTAssertEqual(
            try only().sessionName,
            "Fix the agent titles and useful descriptions",
            "later turns do not silently rename a Codex session"
        )
    }

    func testCodexReportedTitleWinsPromptFallback() throws {
        monitor.ingest(event(
            "prompt", agent: "codex", sessionName: "Agent monitoring",
            prompt: "This prompt is not the title"
        ))
        XCTAssertEqual(try only().sessionName, "Agent monitoring")
    }

    func testCodexMetadataBackfillsTranscriptForRunningOutput() throws {
        var tuning = AgentMonitor.Tuning()
        tuning.sweepInterval = 3600
        tuning.transcriptSampleInterval = 0
        let samplingMonitor = AgentMonitor(
            tuning: tuning,
            transcriptSampler: { agent, path in
                guard agent == "codex", path == "/safe/codex-session.jsonl"
                else { return nil }
                return .init(detail: "Found the issue and applying the fix.")
            },
            codexMetadataResolver: { sessionID in
                guard sessionID == "codex-session" else { return .init() }
                return .init(
                    title: "Fix working output",
                    transcriptPath: "/safe/codex-session.jsonl"
                )
            },
            matchTargets: { [] }
        )

        samplingMonitor.ingest(event(
            "prompt", id: "codex-session", agent: "codex",
            sessionName: "⠹ project", prompt: "Please investigate"
        ))
        samplingMonitor.sweepNow()

        let info = try XCTUnwrap(samplingMonitor.list().first)
        XCTAssertEqual(info.sessionName, "Fix working output")
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.message, "Found the issue and applying the fix.")
        XCTAssertEqual(info.prompt, "Please investigate")
    }

    func testCodexEphemeralThreadNeverBecomesARecord() {
        let filteringMonitor = AgentMonitor(
            tuning: .init(),
            codexMetadataResolver: { _ in .init(threadRecorded: false) },
            matchTargets: { [] }
        )
        filteringMonitor.ingest(event(
            "prompt", id: "ambient-run", agent: "codex",
            prompt: "Generate 0 to 3 hyperpersonalized suggestions"
        ))
        filteringMonitor.ingest(event("stop", id: "ambient-run", agent: "codex"))
        XCTAssertTrue(filteringMonitor.list().isEmpty)
    }

    func testCodexRecordSlippedInWhileDatabaseUnreadableIsRemoved() throws {
        final class VerdictBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Bool?
            func get() -> Bool? { lock.withLock { value } }
            func set(_ next: Bool?) { lock.withLock { value = next } }
        }
        let verdict = VerdictBox()
        let filteringMonitor = AgentMonitor(
            tuning: .init(),
            codexMetadataResolver: { _ in .init(threadRecorded: verdict.get()) },
            matchTargets: { [] }
        )
        filteringMonitor.ingest(event("prompt", id: "ambient-run", agent: "codex"))
        XCTAssertEqual(filteringMonitor.list().count, 1, "no verdict admits the record")

        verdict.set(false)
        filteringMonitor.ingest(event("tool", id: "ambient-run", agent: "codex"))
        XCTAssertTrue(
            filteringMonitor.list().isEmpty,
            "an ephemeral verdict on a later event removes the record"
        )
    }

    func testStopWithAgentErrorAndStickiness() throws {
        monitor.ingest(event("prompt", prompt: "run"))
        monitor.ingest(event("stop", message: "API Error: 500", agentError: true))
        var info = try only()
        XCTAssertEqual(info.state, .error)
        XCTAssertEqual(info.message, "API Error: 500")

        // A notify (e.g. the idle notification) must not mask the failure.
        monitor.ingest(event("notify", message: "Claude is waiting"))
        XCTAssertEqual(try only().state, .error)

        // A new prompt clears it…
        monitor.ingest(event("prompt", prompt: "again"))
        XCTAssertEqual(try only().state, .running)

        // …and so does a session start.
        monitor.ingest(event("stop", agentError: true))
        XCTAssertEqual(try only().state, .error)
        monitor.ingest(event("session-start"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertNil(info.message)
    }

    func testBusyPreservesContextAndClearsError() throws {
        monitor.ingest(event("prompt", prompt: "ship it"))
        monitor.ingest(event("tool", action: "Bash: swift test"))
        monitor.ingest(event("busy"))
        var info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.prompt, "ship it", "busy leaves prompt untouched")
        XCTAssertEqual(info.action, "Bash: swift test", "busy leaves action untouched")

        // busy is a turn-start signal: it clears error stickiness…
        monitor.ingest(event("stop", message: "API Error: 500", agentError: true))
        XCTAssertEqual(try only().state, .error)
        monitor.ingest(event("busy"))
        info = try only()
        XCTAssertEqual(info.state, .running)
        // …and leaves the last agent message in place.
        XCTAssertEqual(info.message, "API Error: 500")
    }

    func testBusyAndToolCanRefreshLastAgentMessage() throws {
        monitor.ingest(event("prompt", prompt: "ship it"))
        monitor.ingest(event("busy", message: "Inspecting the implementation."))
        var info = try only()
        XCTAssertEqual(info.message, "Inspecting the implementation.")

        monitor.ingest(event(
            "tool", message: "Found the source of the stale status.",
            action: "Read: AgentMonitor.swift"
        ))
        info = try only()
        XCTAssertEqual(info.message, "Found the source of the stale status.")
    }

    func testBusyCreatesRecord() throws {
        monitor.ingest(event("busy"))
        XCTAssertEqual(try only().state, .running)
    }

    func testStopWithNilMessagePreservesMessage() throws {
        monitor.ingest(event("notify", message: "Needs review"))
        monitor.ingest(event("stop"))
        let info = try only()
        XCTAssertEqual(info.state, .done)
        XCTAssertEqual(info.message, "Needs review")

        // A provided message still replaces it.
        monitor.ingest(event("stop", message: "All wrapped up"))
        XCTAssertEqual(try only().message, "All wrapped up")
    }

    func testToolWithNilActionFallsBackToLastAgentMessage() throws {
        monitor.ingest(event("notify", message: "I found the relevant files"))
        monitor.ingest(event("busy"))
        monitor.ingest(event("tool", action: "Bash: swift build"))
        monitor.ingest(event("tool"))
        let info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertNil(info.action)
        XCTAssertEqual(info.message, "I found the relevant files")
    }

    func testUnknownEventIgnored() {
        monitor.ingest(event("frobnicate"))
        XCTAssertTrue(monitor.list().isEmpty)
    }

    func testFieldsCappedDefensively() throws {
        monitor.ingest(event(
            "prompt",
            cwd: String(repeating: "d", count: 5000),
            prompt: String(repeating: "p", count: 5000)
        ))
        monitor.ingest(event("tool", cwd: nil, action: String(repeating: "a", count: 5000)))
        monitor.ingest(event(
            "notify", cwd: nil, message: "x\u{07}y" + String(repeating: "m", count: 5000)
        ))
        let info = try only()
        XCTAssertEqual(info.cwd.count, 1024)
        XCTAssertEqual(info.prompt?.count, 200)
        XCTAssertEqual(info.action?.count, 120)
        XCTAssertEqual(info.message?.count, 300)
        XCTAssertFalse(info.message!.unicodeScalars.contains { $0.value < 0x20 })
    }

    // MARK: - Ownership matching

    func testMatchByTTY() throws {
        targets.current = [
            .init(
                sessionId: 7, sessionName: "Claude — TTY.Build",
                ttyPath: "/dev/ttys009", shellPid: 4242
            )
        ]
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys009")
        ]))
        let info = try only()
        XCTAssertEqual(info.sessionId, 7)
        XCTAssertEqual(info.sessionName, "Claude — TTY.Build")
        XCTAssertNil(info.term, "managed agents carry no terminal-app name")
    }

    func testManagedTitleTracksSessionAndReportedNameSurvivesUnmatch() throws {
        targets.current = [
            .init(
                sessionId: 7, sessionName: "Codex — release",
                ttyPath: "/dev/ttys009", shellPid: 4242
            )
        ]
        monitor.ingest(event(
            "prompt", sessionName: "Agent supplied title",
            lineage: [
                AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys009")
            ]
        ))
        XCTAssertEqual(try only().sessionName, "Codex — release")

        targets.current = [
            .init(
                sessionId: 7, sessionName: "Codex — TestFlight",
                ttyPath: "/dev/ttys009", shellPid: 4242
            )
        ]
        monitor.sweepNow()
        XCTAssertEqual(try only().sessionName, "Codex — TestFlight")

        targets.current = []
        monitor.sweepNow()
        let info = try only()
        XCTAssertNil(info.sessionId)
        XCTAssertEqual(info.sessionName, "Agent supplied title")
    }

    func testMatchByShellPidInLineage() throws {
        targets.current = [
            .init(sessionId: 3, ttyPath: "/dev/ttys001", shellPid: 4242)
        ]
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys777"),
            AgentLineageEntry(pid: 4242, name: "zsh", tty: "/dev/ttys777"),
        ]))
        XCTAssertEqual(try only().sessionId, 3)
    }

    func testUnmanagedAgentCarriesTerminalName() throws {
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys004"),
            AgentLineageEntry(pid: 4243, name: "zsh", tty: "/dev/ttys004"),
            AgentLineageEntry(pid: 4244, name: "iTerm2"),
        ]))
        let info = try only()
        XCTAssertNil(info.sessionId)
        XCTAssertEqual(info.term, "iTerm")
    }

    func testUnmatchWhenSessionCloses() throws {
        targets.current = [
            .init(sessionId: 7, ttyPath: "/dev/ttys009", shellPid: 4242)
        ]
        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: livePid, name: "claude", tty: "/dev/ttys009"),
            AgentLineageEntry(pid: 4244, name: "ghostty"),
        ]))
        XCTAssertEqual(try only().sessionId, 7)

        // Session closes under the still-living agent → unmanaged.
        targets.current = []
        monitor.sweepNow()
        let info = try only()
        XCTAssertNil(info.sessionId)
        XCTAssertEqual(info.term, "Ghostty")
    }

    func testTerminalNameTruncatedCommMatches() {
        XCTAssertEqual(
            AgentMonitor.terminalDisplayName(processName: "Code Helper (Plu"),
            "VS Code"
        )
        XCTAssertEqual(AgentMonitor.terminalDisplayName(processName: "tmux"), "tmux")
        XCTAssertNil(AgentMonitor.terminalDisplayName(processName: "systemd"))
    }

    // MARK: - Liveness

    func testDeadAgentPidRemovedOnSweep() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.01"]
        try process.run()
        process.waitUntilExit()
        let deadPid = process.processIdentifier

        monitor.ingest(event("prompt", lineage: [
            AgentLineageEntry(pid: deadPid, name: "claude")
        ]))
        XCTAssertEqual(monitor.list().count, 1)
        monitor.sweepNow()
        XCTAssertTrue(monitor.list().isEmpty)
    }

    func testLiveAgentPidSurvivesSweep() {
        monitor.ingest(event("prompt"))
        monitor.sweepNow()
        XCTAssertEqual(monitor.list().count, 1)
    }

    func testRunningTranscriptSamplingRefreshesAgentMessage() throws {
        final class SampleBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = AgentTranscriptActivity(
                detail: "Inspecting the release workflow"
            )
            func get() -> AgentTranscriptActivity { lock.withLock { value } }
            func set(_ next: AgentTranscriptActivity) { lock.withLock { value = next } }
        }
        let samples = SampleBox()
        var tuning = AgentMonitor.Tuning()
        tuning.debounce = 0
        tuning.sweepInterval = 3600
        tuning.transcriptSampleInterval = 0
        let samplingMonitor = AgentMonitor(
            tuning: tuning,
            transcriptSampler: { _, _ in samples.get() },
            matchTargets: { [] }
        )

        samplingMonitor.ingest(event(
            "prompt", prompt: "Ship it", transcriptPath: "/safe/session.jsonl"
        ))
        samplingMonitor.sweepNow()
        var info = try XCTUnwrap(samplingMonitor.list().first)
        XCTAssertEqual(info.message, "Inspecting the release workflow")
        XCTAssertNil(info.action)

        samples.set(.init(detail: "Tests passed; validating the archive"))
        samplingMonitor.sweepNow()
        info = try XCTUnwrap(samplingMonitor.list().first)
        XCTAssertEqual(info.message, "Tests passed; validating the archive")
        XCTAssertNil(info.action)
    }

    func testTranscriptSamplingAppliesClaudeSessionTitle() throws {
        var tuning = AgentMonitor.Tuning()
        tuning.sweepInterval = 3600
        tuning.transcriptSampleInterval = 0
        let samplingMonitor = AgentMonitor(
            tuning: tuning,
            transcriptSampler: { _, _ in
                .init(sessionTitle: "Investigate push status")
            },
            matchTargets: { [] }
        )
        samplingMonitor.ingest(event(
            "tool", action: "Bash: swift test",
            transcriptPath: "/safe/session.jsonl"
        ))
        samplingMonitor.sweepNow()
        let info = try XCTUnwrap(samplingMonitor.list().first)
        XCTAssertEqual(info.sessionName, "Investigate push status")
        XCTAssertEqual(
            info.action, "Bash: swift test",
            "a title-only sample must not clear the live action"
        )
    }

    func testTranscriptSamplingNeverChangesAttentionState() throws {
        var tuning = AgentMonitor.Tuning()
        tuning.sweepInterval = 3600
        tuning.transcriptSampleInterval = 0
        tuning.stateConfirmationWindow = 0
        let samplingMonitor = AgentMonitor(
            tuning: tuning,
            transcriptSampler: { _, _ in
                .init(detail: "This must not revive a waiting agent")
            },
            matchTargets: { [] }
        )
        samplingMonitor.ingest(event(
            "ask", transcriptPath: "/safe/session.jsonl"
        ))
        samplingMonitor.sweepNow()
        let info = try XCTUnwrap(samplingMonitor.list().first)
        XCTAssertEqual(info.state, .waiting)
        XCTAssertEqual(info.message, "Waiting for your answer")
    }

    // MARK: - Debounce

    func testTwoIngestsWithinWindowPublishOnce() {
        let counter = Counter()
        monitor.onChange = { _ in counter.increment() }
        monitor.ingest(event("prompt", prompt: "one"))
        monitor.ingest(event("tool", action: "Bash: ls"))

        let expectation = expectation(description: "debounce window elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(counter.value, 1)
    }

    func testPublishCarriesSortedSnapshot() {
        let received = Received()
        monitor.onChange = { received.append($0) }
        monitor.ingest(event("prompt", id: "a-1"))
        monitor.ingest(event("prompt", id: "a-2"))

        let expectation = expectation(description: "debounce window elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        let last = received.all.last
        XCTAssertEqual(last?.count, 2)
        XCTAssertEqual(last?.first?.id, "a-2", "most recently updated first")
    }

    // MARK: - Live Activity attention transitions

    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(info: AgentInfo, attention: AgentActivity.Attention)] = []
        var all: [(info: AgentInfo, attention: AgentActivity.Attention)] { lock.withLock { events } }
        func append(_ info: AgentInfo, _ attention: AgentActivity.Attention) {
            lock.withLock { events.append((info, attention)) }
        }
    }

    func testAttentionFiresOnEntryEdgesOnly() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }

        monitor.ingest(event("session-start"))
        monitor.ingest(event("prompt", prompt: "go"))
        XCTAssertTrue(updates.all.isEmpty, "running states never notify")

        // Claude fires ask (PreToolUse) and then notify (Notification hook)
        // for the same question: one notification, not two.
        monitor.ingest(event("ask"))
        monitor.ingest(event("notify", message: "Permission needed"))
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .waiting)
        XCTAssertEqual(updates.all.first?.info.message, "Waiting for your answer")

        // Answering (prompt) and a fresh ask is a new edge.
        monitor.ingest(event("prompt", prompt: "yes"))
        monitor.ingest(event("ask", message: "Pick a plan"))
        XCTAssertEqual(updates.all.count, 2)
        XCTAssertEqual(updates.all.last?.info.message, "Pick a plan")

        // Work resumes after the question, then turn end reports done with
        // the final message — after the hold-back window, not on the edge.
        monitor.ingest(event("busy"))
        monitor.ingest(event("stop", message: "All tests pass"))
        XCTAssertEqual(updates.all.count, 2, "done is held back, not immediate")
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 3)
        XCTAssertEqual(updates.all.last?.attention, .done)
        XCTAssertEqual(updates.all.last?.info.message, "All tests pass")

        // A repeated stop in the same state is not an edge.
        monitor.ingest(event("stop"))
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 3)
    }

    func testTransitionsAmongAttentionStatesNeverAlert() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }

        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("ask", message: "Choose one"))
        XCTAssertEqual(updates.all.map(\.attention), [.waiting])

        monitor.ingest(event("stop", message: "Stopped while waiting"))
        waitPastDoneDelay()
        XCTAssertEqual(
            updates.all.map(\.attention),
            [.waiting],
            "waiting to done is not a working-to-attention edge"
        )

        monitor.ingest(event("stop", agentError: true))
        XCTAssertEqual(
            updates.all.map(\.attention),
            [.waiting],
            "done to error also stays silent"
        )
    }

    func testAttentionFiresOnErrorStop() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop", agentError: true))
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .error)

        // Sticky error: the idle notify must not re-notify (or downgrade).
        monitor.ingest(event("notify", message: "waiting for input"))
        XCTAssertEqual(updates.all.count, 1)
    }

    func testIdleNotifyAfterStopStaysDone() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop", message: "All tests pass"))

        // Claude's idle Notification hook fires ~60s after a finished turn;
        // it must not flip done back to waiting ("needs your input" right
        // after "finished"), overwrite the finish summary, or cancel the
        // held-back done push (the state did not change).
        monitor.ingest(event("notify", message: "Claude is waiting for your input"))
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .done)
        let info = monitor.list().first
        XCTAssertEqual(info?.state, .done)
        XCTAssertEqual(info?.message, "All tests pass")

        // The next turn still reaches waiting normally.
        monitor.ingest(event("prompt", prompt: "continue"))
        monitor.ingest(event("notify", message: "Permission needed"))
        XCTAssertEqual(updates.all.count, 2)
        XCTAssertEqual(updates.all.last?.attention, .waiting)
    }

    func testDonePushCancelledWhenParkedTurnResumes() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }

        // Claude parks waiting on a background subagent: Stop fires, then the
        // main loop resumes inside the hold-back window. No push at all.
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop", message: "Launched the build agent"))
        monitor.ingest(event("tool", action: "Bash: swift test"))
        waitPastDoneDelay()
        XCTAssertTrue(updates.all.isEmpty, "resumed park must swallow the done push")

        // The real completion still lands after the window.
        monitor.ingest(event("stop", message: "All done"))
        waitPastDoneDelay()
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .done)
        XCTAssertEqual(updates.all.first?.info.message, "All done")
    }

    func testDonePushCancelledByDismiss() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event("stop"))
        monitor.dismiss(id: "a-1")
        waitPastDoneDelay()
        XCTAssertTrue(updates.all.isEmpty, "dismissing the agent cancels the held push")
    }

    func testSessionEndDoesNotNotify() {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(AgentEvent(agent: "claude", event: "session-end", agentSessionId: "a-1"))
        XCTAssertTrue(updates.all.isEmpty)
        XCTAssertTrue(monitor.list().isEmpty)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [[AgentInfo]] = []
    var all: [[AgentInfo]] { lock.withLock { lists } }
    func append(_ list: [AgentInfo]) { lock.withLock { lists.append(list) } }
}

// MARK: - Confirmation window, notify kinds, seq ordering, reported agent pid

extension AgentMonitorTests {
    /// Monitor with a short but real confirmation window; edges out of
    /// running stay invisible until the window elapses uncontradicted.
    private func makeWindowedMonitor(
        window: TimeInterval, doneDelay: TimeInterval = 0.05
    ) -> AgentMonitor {
        var tuning = AgentMonitor.Tuning()
        tuning.debounce = 0.01
        tuning.sweepInterval = 3600
        tuning.doneAttentionDelay = doneDelay
        tuning.stateConfirmationWindow = window
        return AgentMonitor(
            tuning: tuning,
            codexMetadataResolver: { _ in .init() },
            matchTargets: { [] }
        )
    }

    private func wait(_ interval: TimeInterval) {
        let expectation = expectation(description: "interval elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: interval + 2)
    }

    func testFalseStopInsideWindowNeverBecomesVisible() throws {
        let windowed = makeWindowedMonitor(window: 0.3)
        let updates = Updates()
        windowed.onAttention = { updates.append($0, $1) }

        windowed.ingest(event("prompt", prompt: "go"))
        // Tool-loop park: stop immediately followed by more work.
        windowed.ingest(event("stop", message: "intermediate output"))
        XCTAssertEqual(windowed.list().first?.state, .running, "edge is held")
        windowed.ingest(event("tool", action: "Bash: swift test"))

        wait(0.6)
        XCTAssertEqual(
            windowed.list().first?.state, .running,
            "a stop contradicted inside the window never becomes visible"
        )
        XCTAssertTrue(updates.all.isEmpty)
    }

    func testStopConfirmedAfterWindowCommitsDoneAndAttention() throws {
        let windowed = makeWindowedMonitor(window: 0.15)
        let updates = Updates()
        windowed.onAttention = { updates.append($0, $1) }

        windowed.ingest(event("prompt", prompt: "go"))
        windowed.ingest(event("stop", message: "All done"))
        XCTAssertEqual(windowed.list().first?.state, .running)

        wait(0.5)
        XCTAssertEqual(windowed.list().first?.state, .done)
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .done)
        XCTAssertEqual(updates.all.first?.info.message, "All done")
    }

    func testEdgeSupersededInsideWindowCommitsLatestState() throws {
        let windowed = makeWindowedMonitor(window: 0.2)
        let updates = Updates()
        windowed.onAttention = { updates.append($0, $1) }

        windowed.ingest(event("prompt", prompt: "go"))
        windowed.ingest(event("stop"))
        // The park was actually a question: ask arrives inside the window.
        windowed.ingest(event("ask"))

        wait(0.5)
        XCTAssertEqual(windowed.list().first?.state, .waiting)
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .waiting)
    }

    func testWaitingConfirmedAfterWindow() throws {
        let windowed = makeWindowedMonitor(window: 0.15)
        let updates = Updates()
        windowed.onAttention = { updates.append($0, $1) }

        windowed.ingest(event("prompt", prompt: "go"))
        windowed.ingest(event("ask"))
        XCTAssertEqual(
            windowed.list().first?.state, .running,
            "waiting is held for the window too"
        )
        wait(0.4)
        XCTAssertEqual(windowed.list().first?.state, .waiting)
        XCTAssertEqual(updates.all.count, 1)
        XCTAssertEqual(updates.all.first?.attention, .waiting)
    }

    func testNotifyOtherKindNeverChangesState() throws {
        let updates = Updates()
        monitor.onAttention = { updates.append($0, $1) }
        monitor.ingest(event("prompt", prompt: "go"))
        monitor.ingest(event(
            "notify", message: "A new version is available", notifyKind: "other"
        ))
        let info = try only()
        XCTAssertEqual(info.state, .running)
        XCTAssertNil(info.message, "noise notifications must not replace the message")
        XCTAssertTrue(updates.all.isEmpty)
    }

    func testNotifyPermissionAndIdleKindsStillWait() throws {
        monitor.ingest(event(
            "notify", id: "perm-1", message: "Needs permission", notifyKind: "permission"
        ))
        XCTAssertEqual(
            monitor.list().first { $0.id == "perm-1" }?.state, .waiting
        )
        monitor.ingest(event(
            "notify", id: "idle-1", message: "Waiting for your input", notifyKind: "idle"
        ))
        XCTAssertEqual(
            monitor.list().first { $0.id == "idle-1" }?.state, .waiting
        )
    }

    func testStaleSeqIsDropped() throws {
        monitor.ingest(event("busy", seq: 100))
        monitor.ingest(event("stop", seq: 300))
        XCTAssertEqual(try only().state, .done)

        // A racing tool report captured before the stop arrives late: it
        // must not rewind done back to running.
        monitor.ingest(event("tool", action: "Bash: late", seq: 200))
        let info = try only()
        XCTAssertEqual(info.state, .done)
        XCTAssertNil(info.action)
    }

    func testSeqlessEventsKeepLegacyOrdering() throws {
        // Reporters older than the seq field interleave with newer ones.
        monitor.ingest(event("busy", seq: 100))
        monitor.ingest(event("ask"))
        XCTAssertEqual(try only().state, .waiting)
    }

    func testReportedAgentPidPreferredForLiveness() throws {
        // A pid that is certainly dead by the time the sweep runs.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run()
        probe.waitUntilExit()
        let deadPid = probe.processIdentifier

        // The lineage alone offers only a live shell (the old heuristic
        // would find no agent pid and fall back to slow idle expiry); the
        // reporter's explicit pid must win, so the sweep reaps immediately.
        monitor.ingest(event(
            "busy", agentPid: deadPid,
            lineage: [AgentLineageEntry(pid: livePid, name: "zsh")]
        ))
        XCTAssertEqual(monitor.list().count, 1)
        monitor.sweepNow()
        XCTAssertTrue(monitor.list().isEmpty)
    }
}

extension AgentMonitorTests {
    func testDismissRemovesRecordUntilNextEvent() throws {
        monitor.ingest(event("stop", message: "All done"))
        XCTAssertEqual(monitor.list().count, 1)

        monitor.dismiss(id: "a-1")
        XCTAssertTrue(monitor.list().isEmpty)

        // The agent's next hook event recreates the record.
        monitor.ingest(event("prompt", prompt: "again"))
        XCTAssertEqual(monitor.list().count, 1)
        XCTAssertEqual(monitor.list().first?.state, .running)
    }
}
