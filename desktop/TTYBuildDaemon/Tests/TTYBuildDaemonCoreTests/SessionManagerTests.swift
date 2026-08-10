import Foundation
import XCTest

@testable import TTYBuildDaemonCore

/// Hermetic shell for tests: plain /bin/sh, no rc files, no login shell.
private func testOptions() -> SessionManager.Options {
    SessionManager.Options(shell: "/bin/sh", shellArguments: [], extraEnvironment: ["PS1": "$ "])
}

final class SessionManagerTests: XCTestCase {
    func testSpawnEchoAndReadOutput() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertEqual(id, 1)

        manager.write(id: id, data: Data("printf 'ttybuild-%s\\n' hi\n".utf8))
        try collected.wait(for: "ttybuild-hi", timeout: 10)

        let sessions = manager.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, id)
        XCTAssertTrue(sessions[0].alive)
        XCTAssertEqual(sessions[0].cols, 80)
        XCTAssertEqual(sessions[0].rows, 24)
    }

    func testPromptEndMarkerIsAlwaysEmpty() throws {
        var options = testOptions()
        options.extraEnvironment["PROMPT_EOL_MARK"] = "visible"
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(
            id: id,
            data: Data("printf 'prompt-eol-length=%s\\n' \"${#PROMPT_EOL_MARK}\"\n".utf8)
        )
        try collected.wait(for: "prompt-eol-length=0", timeout: 10)
    }

    func testNoColorIsAlwaysRemoved() throws {
        var options = testOptions()
        options.extraEnvironment["NO_COLOR"] = "1"
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(
            id: id,
            data: Data("if [ \"${NO_COLOR+x}\" = x ]; then echo no-color-present; else echo no-color-absent; fi\n".utf8)
        )
        try collected.wait(for: "no-color-absent", timeout: 10)
    }

    func testSessionIdsStartAtConfiguredHighWaterMark() throws {
        // Session-channel keys are derived from (secret, sid); a restarted
        // daemon must never hand out an old sid (PROTOCOL.md §4.1).
        var options = testOptions()
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
        var options = testOptions()
        options.maximumSessions = 1
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        _ = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertThrowsError(try manager.create(cwd: nil, cols: 80, rows: 24)) { error in
            XCTAssertEqual(error as? SessionManager.SessionError, .capacityReached(1))
        }
        XCTAssertEqual(manager.list().count, 1)
    }

    func testSessionIDCannotExceedRelayUInt32Space() {
        var options = testOptions()
        options.firstSessionId = Int(UInt32.max) + 1
        let manager = SessionManager(options: options)

        XCTAssertThrowsError(try manager.create(cwd: nil, cols: 80, rows: 24)) { error in
            XCTAssertEqual(error as? SessionManager.SessionError, .idSpaceExhausted)
        }
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testReplaySnapshotContainsPastOutput() throws {
        let manager = SessionManager(options: testOptions())
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
        let options = SessionManager.Options(
            shell: "/bin/zsh",
            shellArguments: ["-f"],
            extraEnvironment: [
                "PS1": "$ ",
                "TTYBUILD_TEST_READY": "ORDERED-READY",
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
                #"/bin/sh -c 'on_winch() { printf "%s\n" ORDERED-WINCH; }; trap on_winch WINCH; printf "%s\n" "$TTYBUILD_TEST_READY"; while :; do sleep 1; done'"#.appending("\n").utf8
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
        let options = SessionManager.Options(
            shell: "/bin/zsh",
            shellArguments: ["-f"],
            extraEnvironment: ["PS1": "$ "]
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
        let options = SessionManager.Options(
            shell: "/bin/zsh",
            shellArguments: ["-f"],
            extraEnvironment: [
                "PS1": "$ ",
                "TTYBUILD_TEST_READY": "ZSH-CHILD-ARMED",
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
                #"/bin/sh -c 'on_winch() { printf "ZSH-CHILD-WINCH:%s\n" "$(stty size)"; }; trap on_winch WINCH; printf "%s\n" "$TTYBUILD_TEST_READY"; while :; do sleep 1; done'"#.appending("\n").utf8
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

    func testLiveCwdFollowsShellChdir() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("cd /private/var && printf 'moved-%s\\n' ok\n".utf8))
        try collected.wait(for: "moved-ok", timeout: 10)

        // The cwd poll runs every 2 s; give it two cycles.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if manager.list().first?.cwd == "/private/var" { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("cwd never updated to /private/var, got \(manager.list().first?.cwd ?? "nil")")
    }

    func testExitReportsEventAndMarksDead() throws {
        let manager = SessionManager(options: testOptions())
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
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertTrue(manager.close(id: id))
        XCTAssertFalse(manager.close(id: id), "double close reports failure")
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testOSCTitleUpdatesSessionInfo() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let titled = expectation(description: "title event")
        let title = LockedBox<String>()
        manager.onEvent = { event in
            if case .title(_, let value) = event, value == "ttybuild-title" {
                title.value = value
                titled.fulfill()
            }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("printf '\\033]2;ttybuild-title\\007'\n".utf8))
        wait(for: [titled], timeout: 10)

        XCTAssertEqual(title.value, "ttybuild-title")
        XCTAssertEqual(manager.list().first?.title, "ttybuild-title")
    }

    func testOSCTitleSamplingCoalescesAnimationWithoutRebroadcastingSessions() throws {
        var options = testOptions()
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
