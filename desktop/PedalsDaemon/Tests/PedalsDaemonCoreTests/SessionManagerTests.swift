import Foundation
import XCTest

@testable import PedalsDaemonCore

/// Hermetic shell for tests: the fake tmux execs plain /bin/sh, no rc files,
/// no login shell. Extra environment reaches the pane via `new-session -e`.
private func testOptions(
    fixture: FakeTmux.Fixture,
    extraEnvironment: [String: String] = [:]
) -> SessionManager.Options {
    fixture.sessionOptions(
        extraEnvironment: ["PS1": "$ "].merging(extraEnvironment) { _, new in new }
    )
}

final class SessionManagerTests: XCTestCase {
    private var fixture: FakeTmux.Fixture!

    override func setUpWithError() throws {
        fixture = try FakeTmux.makeFixture()
    }

    override func tearDownWithError() throws {
        fixture.cleanUp()
    }

    func testSpawnEchoAndReadOutput() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertEqual(id, 1)

        manager.write(id: id, data: Data("printf 'pedals-%s\\n' hi\n".utf8))
        try collected.wait(for: "pedals-hi", timeout: 10)

        let sessions = manager.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, id)
        XCTAssertTrue(sessions[0].alive)
        XCTAssertEqual(sessions[0].cols, 80)
        XCTAssertEqual(sessions[0].rows, 24)
    }

    func testCreateSpawnsTmuxNewSessionArgv() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        let id = try manager.create(cwd: "/tmp", cols: 80, rows: 24)

        XCTAssertTrue(
            fixture.waitForInvocation(
                containing: "new-session -s pedals-\(id) -x 80 -y 24 -c /tmp"
            ),
            "spawn argv must be the tmux new-session form, got \(fixture.invocations())"
        )
        let invocation = fixture.invocations().first { $0.contains("new-session") }
        XCTAssertTrue(invocation?.contains("-e COLORTERM=truecolor") == true)
        XCTAssertTrue(invocation?.contains("-e PROMPT_EOL_MARK=") == true)
    }

    func testSessionIdsStartAtConfiguredHighWaterMark() throws {
        // Session-channel keys are derived from (secret, sid); a restarted
        // daemon must never hand out an old sid (PROTOCOL.md §4.1).
        var options = testOptions(fixture: fixture)
        options.firstSessionId = 7
        let allocated = LockedBox<Int>()
        options.onIdAllocated = { allocated.value = $0 }
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertEqual(id, 7)
        XCTAssertEqual(allocated.value, 7)
        XCTAssertEqual(try manager.create(cwd: nil, cols: 80, rows: 24), 8)
        XCTAssertEqual(allocated.value, 8)
    }

    func testDirectoryCapacityIsEnforcedBeforeAllocatingAnotherPTY() throws {
        var options = testOptions(fixture: fixture)
        options.maximumSessions = 1
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        _ = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertThrowsError(try manager.create(cwd: nil, cols: 80, rows: 24)) { error in
            XCTAssertEqual(error as? SessionManager.SessionError, .capacityReached(1))
        }
        XCTAssertEqual(manager.list().count, 1)
    }

    func testSessionIDCannotExceedRelayUInt32Space() throws {
        var options = testOptions(fixture: fixture)
        options.firstSessionId = Int(UInt32.max) + 1
        let manager = SessionManager(options: options)

        XCTAssertThrowsError(try manager.create(cwd: nil, cols: 80, rows: 24)) { error in
            XCTAssertEqual(error as? SessionManager.SessionError, .idSpaceExhausted)
        }
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testReplaySnapshotContainsPastOutput() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("printf 'replay-%s\\n' me\n".utf8))
        try collected.wait(for: "replay-me", timeout: 10)

        let snapshot = try XCTUnwrap(manager.replaySnapshot(id: id))
        let text = String(decoding: snapshot.data, as: UTF8.self)
        XCTAssertTrue(text.contains("replay-me"), "ring buffer must hold past output")
        XCTAssertEqual(snapshot.coversUpTo, UInt64(snapshot.data.count))
        XCTAssertEqual(snapshot.cols, 80)
        XCTAssertEqual(snapshot.rows, 24)
    }

    func testResizeEventPrecedesOutputFromForegroundJobSIGWINCH() throws {
        let options = testOptions(
            fixture: fixture,
            extraEnvironment: [
                "FAKE_TMUX_SHELL": "/bin/zsh -f",
                "PEDALS_TEST_READY": "ORDERED-READY",
            ]
        )
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let collected = OutputCollector()
        let ordered = ResizeOutputOrderCollector(marker: "ORDERED-WINCH")
        manager.onEvent = { event in
            ordered.accept(event)
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(
            id: id,
            data: Data(
                #"/bin/sh -c 'on_winch() { printf "%s\n" ORDERED-WINCH; }; trap on_winch WINCH; printf "%s\n" "$PEDALS_TEST_READY"; while :; do sleep 1; done'"#.appending("\n").utf8
            )
        )
        // The readiness value comes from the environment, so the interactive
        // shell's echoed command cannot satisfy this wait before the child has
        // installed its signal handler.
        try collected.wait(for: "ORDERED-READY", timeout: 10)

        // The PTY echoes the command itself, including the marker text. Start
        // the ordering observation only after the foreground job is armed.
        ordered.reset()
        manager.resize(id: id, cols: 91, rows: 33)
        try ordered.wait(timeout: 3)

        XCTAssertEqual(ordered.values, ["resize:91x33", "output"])
    }

    func testSpawnedShellHasAControllingTerminal() throws {
        let options = testOptions(
            fixture: fixture,
            extraEnvironment: ["FAKE_TMUX_SHELL": "/bin/zsh -f"]
        )
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(
            id: id,
            data: Data(
                "if [ \"$(ps -o tpgid= -p $$ | tr -d ' ')\" -gt 0 ]; then result=CONTROLLING; else result=NO-CONTROLLING; fi; printf '%s%s\\n' \"$result\" -TTY\n".utf8
            )
        )

        try collected.wait(for: "\r\nCONTROLLING-TTY\r\n", timeout: 10)
        XCTAssertFalse(collected.text.contains("\r\nNO-CONTROLLING-TTY\r\n"))
    }

    func testRepeatedResizeSignalsForegroundJobLaunchedByZsh() throws {
        let options = testOptions(
            fixture: fixture,
            extraEnvironment: [
                "FAKE_TMUX_SHELL": "/bin/zsh -f",
                "PEDALS_TEST_READY": "ZSH-CHILD-ARMED",
            ]
        )
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(
            id: id,
            data: Data(
                #"/bin/sh -c 'on_winch() { printf "ZSH-CHILD-WINCH:%s\n" "$(stty size)"; }; trap on_winch WINCH; printf "%s\n" "$PEDALS_TEST_READY"; while :; do sleep 1; done'"#.appending("\n").utf8
            )
        )
        // The readiness value comes from the environment, so the interactive
        // shell's echoed command cannot satisfy this wait before the child has
        // installed its signal handler.
        try collected.wait(for: "ZSH-CHILD-ARMED", timeout: 10)

        for (cols, rows) in [(91, 33), (77, 18), (100, 42)] {
            manager.resize(id: id, cols: UInt16(cols), rows: UInt16(rows))
            try collected.wait(for: "ZSH-CHILD-WINCH:\(rows) \(cols)", timeout: 2)
        }
    }

    func testLiveCwdFollowsPaneCurrentPathPoll() throws {
        var options = testOptions(fixture: fixture)
        options.metadataSampleInterval = 0.1
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let id = try manager.create(cwd: "/tmp", cols: 80, rows: 24)
        XCTAssertEqual(manager.list().first?.cwd, "/tmp")

        // The pane reports a new working directory on the next list-panes poll.
        try fixture.setPaneMeta(
            sessionName: "pedals-\(id)",
            tty: "/dev/ttys041", pid: 4242,
            path: "/private/var", command: "vim"
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if manager.list().first?.cwd == "/private/var" { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("cwd never updated to /private/var, got \(manager.list().first?.cwd ?? "nil")")
    }

    func testPaneCommandFallbackTitleFollowsPoll() throws {
        var options = testOptions(fixture: fixture)
        options.metadataSampleInterval = 0.1
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let titled = expectation(description: "pane-command fallback title")
        let title = LockedBox<String>()
        manager.onEvent = { event in
            if case .title(_, let value) = event, value == "vim — /private/var" {
                title.value = value
                titled.fulfill()
            }
        }

        let id = try manager.create(cwd: "/tmp", cols: 80, rows: 24)
        try fixture.setPaneMeta(
            sessionName: "pedals-\(id)",
            tty: "/dev/ttys041", pid: 4242,
            path: "/private/var", command: "vim"
        )
        wait(for: [titled], timeout: 5)

        XCTAssertEqual(title.value, "vim — /private/var")
        XCTAssertEqual(manager.list().first?.title, "vim — /private/var")
    }

    func testOSCTitleWinsOverPaneCommandFallback() throws {
        var options = testOptions(fixture: fixture)
        options.metadataSampleInterval = 0.1
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let titled = expectation(description: "OSC title event")
        manager.onEvent = { event in
            if case .title(_, let value) = event, value == "osc-wins" {
                titled.fulfill()
            }
        }

        let id = try manager.create(cwd: "/tmp", cols: 80, rows: 24)
        manager.write(id: id, data: Data("printf '\\033]2;osc-wins\\007'\n".utf8))
        wait(for: [titled], timeout: 10)

        // Later polls keep reporting a pane command, but once an OSC title
        // arrived it owns the session title.
        try fixture.setPaneMeta(
            sessionName: "pedals-\(id)",
            tty: "/dev/ttys041", pid: 4242,
            path: "/private/var", command: "vim"
        )
        let settled = expectation(description: "several poll cycles elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(manager.list().first?.title, "osc-wins")
    }

    func testExitReportsEventAndMarksDead() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        let exited = expectation(description: "exit event")
        let exitCode = LockedBox<Int>()
        manager.onEvent = { event in
            if case .exit(_, let code) = event {
                exitCode.value = code
                exited.fulfill()
            }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("exit 3\n".utf8))
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(exitCode.value, 3)
        let sessions = manager.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].alive)
    }

    func testCloseKillsAndRemoves() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertTrue(manager.close(id: id))
        XCTAssertFalse(manager.close(id: id), "double close reports failure")
        XCTAssertTrue(manager.list().isEmpty)
        XCTAssertTrue(
            fixture.waitForInvocation(containing: "kill-session -t pedals-\(id)"),
            "close must kill the tmux session, got \(fixture.invocations())"
        )
    }

    func testCloseAllKillsEverySessionAndTheServer() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))

        let first = try manager.create(cwd: nil, cols: 80, rows: 24)
        let second = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.closeAll()

        XCTAssertTrue(manager.list().isEmpty)
        XCTAssertTrue(
            fixture.waitForInvocation(containing: "kill-session -t pedals-\(first)")
        )
        XCTAssertTrue(
            fixture.waitForInvocation(containing: "kill-session -t pedals-\(second)")
        )
        XCTAssertTrue(
            fixture.waitForInvocation(containing: "kill-server"),
            "closeAll must kill the private tmux server, got \(fixture.invocations())"
        )
    }

    func testTmuxAttachCommandTracksLiveSessions() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        XCTAssertNil(manager.tmuxAttachCommand(id: 999))

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        let command = try XCTUnwrap(manager.tmuxAttachCommand(id: id))
        XCTAssertEqual(command, fixture.configuration.attachCommand(id: id))
        XCTAssertTrue(command.contains("attach-session -t"))

        XCTAssertTrue(manager.close(id: id))
        XCTAssertNil(manager.tmuxAttachCommand(id: id))
    }

    func testAgentMatchTargetsHaveNoPaneIdentityBeforeFirstPoll() throws {
        var options = testOptions(fixture: fixture)
        // Effectively never polls during this test.
        options.metadataSampleInterval = 3600
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)

        let targets = manager.agentMatchTargets()
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0].sessionId, id)
        XCTAssertNil(targets[0].ttyPath)
        XCTAssertEqual(targets[0].shellPid, 0)
    }

    func testAgentMatchTargetsUsePaneTTYAndPIDAfterPoll() throws {
        var options = testOptions(fixture: fixture)
        options.metadataSampleInterval = 0.1
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        try fixture.setPaneMeta(
            sessionName: "pedals-\(id)",
            tty: "/dev/ttys077", pid: 424242,
            path: "/tmp", command: "zsh"
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let targets = manager.agentMatchTargets()
            if targets.first?.ttyPath == "/dev/ttys077",
               targets.first?.shellPid == 424242 {
                XCTAssertEqual(targets.first?.sessionId, id)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("pane identity never arrived, got \(manager.agentMatchTargets())")
    }

    func testOSCTitleUpdatesSessionInfo() throws {
        let manager = SessionManager(options: testOptions(fixture: fixture))
        defer { manager.closeAll() }

        let titled = expectation(description: "title event")
        let title = LockedBox<String>()
        manager.onEvent = { event in
            if case .title(_, let value) = event, value == "pedals-title" {
                title.value = value
                titled.fulfill()
            }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("printf '\\033]2;pedals-title\\007'\n".utf8))
        wait(for: [titled], timeout: 10)

        XCTAssertEqual(title.value, "pedals-title")
        XCTAssertEqual(manager.list().first?.title, "pedals-title")
    }

    func testOSCTitleSamplingCoalescesAnimationWithoutRebroadcastingSessions() throws {
        var options = testOptions(fixture: fixture)
        options.metadataSampleInterval = 0.25
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let sampled = expectation(description: "sampled final title")
        let titles = LockedArray<String>()
        let listBroadcasts = LockedCounter()
        manager.onEvent = { event in
            switch event {
            case .title(_, let value):
                titles.append(value)
                if value == "final-title" { sampled.fulfill() }
            case .sessionsChanged:
                listBroadcasts.increment()
            default:
                break
            }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        let baselineLists = listBroadcasts.value
        let animatedTitles =
            "printf '\\033]2;spin-1\\007'; sleep 0.03; "
            + "printf '\\033]2;spin-2\\007'; sleep 0.03; "
            + "printf '\\033]2;final-title\\007'\n"
        manager.write(
            id: id,
            data: Data(animatedTitles.utf8)
        )
        wait(for: [sampled], timeout: 5)

        let sampledTitles = titles.values
        XCTAssertEqual(sampledTitles.last, "final-title")
        XCTAssertLessThan(
            sampledTitles.count, 3,
            "sampling may straddle one timer tick but must coalesce the three source titles"
        )
        XCTAssertEqual(
            listBroadcasts.value, baselineLists,
            "a title has its own compact event and must not rebroadcast sessions"
        )
        XCTAssertEqual(manager.list().first?.title, "final-title")
    }
}

// MARK: - helpers

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func wait(for needle: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains(needle) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "OutputCollector", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(needle); got: \(text)"]
        )
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Element] = []

    func append(_ value: Element) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class ResizeOutputOrderCollector: @unchecked Sendable {
    private let marker: Data
    private let lock = NSLock()
    private var stored: [String] = []

    init(marker: String) {
        self.marker = Data(marker.utf8)
    }

    func accept(_ event: SessionEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .resized(_, let cols, let rows):
            stored.append("resize:\(cols)x\(rows)")
        case .output(_, let data, _) where data.range(of: marker) != nil:
            stored.append("output")
        default:
            break
        }
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func reset() {
        lock.lock()
        stored.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func wait(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if values.count >= 2 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "ResizeOutputOrderCollector", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for resize/output: \(values)"]
        )
    }
}
