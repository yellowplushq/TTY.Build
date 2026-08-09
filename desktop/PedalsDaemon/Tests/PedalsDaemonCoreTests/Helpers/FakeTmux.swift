import Foundation

@testable import PedalsDaemonCore

/// A fake `tmux` executable (a bash script) plus per-test fixtures for the
/// state it records. Unit tests point `TmuxConfiguration(binaryPath:)` at the
/// script; it implements just enough of the tmux CLI for SessionManager and
/// TmuxConfiguration tests: `new-session` (execs a real interactive shell on
/// the PTY), `kill-session`, `kill-server`, and `list-panes`.
///
/// Isolation: the script is generated once per test-process run, but all
/// per-server state lives in "<socketPath>.state" / "<socketPath>.log", so
/// each test gets its own server by using a unique socket path.
enum FakeTmux {
    /// Path of the generated fake `tmux` script (created lazily, once).
    static let binaryPath: String = {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pedals-faketmux-\(getpid())", isDirectory: true)
        let binary = directory.appendingPathComponent("tmux")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try script.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: binary.path
            )
        } catch {
            fatalError("cannot create fake tmux: \(error)")
        }
        return binary.path
    }()

    /// One isolated fake-server fixture: unique socket/config paths in a
    /// private temp directory, plus accessors for the fake's recorded state.
    struct Fixture {
        let directory: URL
        let configuration: TmuxConfiguration

        var socketPath: String { configuration.socketPath }
        var stateDirectory: URL {
            URL(fileURLWithPath: socketPath + ".state", isDirectory: true)
        }
        private var logURL: URL { URL(fileURLWithPath: socketPath + ".log") }

        /// Session options whose panes run a hermetic `/bin/sh` (no rc
        /// files); merge `extraEnvironment` over that default.
        func sessionOptions(
            extraEnvironment: [String: String] = [:]
        ) -> SessionManager.Options {
            var environment = ["FAKE_TMUX_SHELL": "/bin/sh"]
            for (key, value) in extraEnvironment { environment[key] = value }
            return SessionManager.Options(
                tmux: configuration, extraEnvironment: environment
            )
        }

        /// Every fake invocation, one line per call (argv after the global
        /// `-S`/`-f` flags, space-separated).
        func invocations() -> [String] {
            guard let text = try? String(contentsOf: logURL, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n").map(String.init)
        }

        /// Polls the invocation log until a line contains `needle`. The log
        /// is written by the fake process, so it lags the spawn/close call
        /// that triggered it.
        @discardableResult
        func waitForInvocation(
            containing needle: String, timeout: TimeInterval = 5
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if invocations().contains(where: { $0.contains(needle) }) { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return false
        }

        /// Overrides what `list-panes` reports for a session: tty, pane pid,
        /// current path, and current command. This is how tests drive the
        /// cwd/title/agent-match polling deterministically.
        func setPaneMeta(
            sessionName: String, tty: String, pid: Int32,
            path: String, command: String
        ) throws {
            let state = stateDirectory
            try FileManager.default.createDirectory(
                at: state, withIntermediateDirectories: true
            )
            let line = [tty, String(pid), path, command].joined(separator: "\t")
            try line.write(
                to: state.appendingPathComponent("\(sessionName).panemeta"),
                atomically: true, encoding: .utf8
            )
        }

        /// Writes the state files the fake's `list-panes` reads, without
        /// spawning anything. `pid` must name a live process (the fake drops
        /// dead sessions); the test process's own pid works.
        func recordSession(name: String, pid: Int32, cwd: String, command: String) throws {
            let state = stateDirectory
            try FileManager.default.createDirectory(
                at: state, withIntermediateDirectories: true
            )
            try String(pid).write(
                to: state.appendingPathComponent("\(name).pid"),
                atomically: true, encoding: .utf8
            )
            try cwd.write(
                to: state.appendingPathComponent("\(name).cwd"),
                atomically: true, encoding: .utf8
            )
            try command.write(
                to: state.appendingPathComponent("\(name).cmd"),
                atomically: true, encoding: .utf8
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: stateDirectory)
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: socketPath + ".log")
            )
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func makeFixture() throws -> Fixture {
        _ = binaryPath // force script generation
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "pedals-ft-\(UUID().uuidString.prefix(8))", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return Fixture(
            directory: directory,
            configuration: TmuxConfiguration(
                binaryPath: binaryPath,
                socketPath: directory.appendingPathComponent("tmux.sock").path,
                configPath: directory.appendingPathComponent("tmux.conf").path
            )
        )
    }

    // MARK: - The fake tmux script

    /// Bash 3.2 compatible (the macOS system bash). Behavior contract:
    /// - Global `-S <sock>` / `-f <conf>` flags are stripped; state derives
    ///   from the socket path.
    /// - `new-session -s NAME -x C -y R -c DIR -e K=V ...` exports each `-e`
    ///   pair, records NAME → child pid (plus cwd and shell name for
    ///   `list-panes` defaults), then execs a real interactive shell:
    ///   `$FAKE_TMUX_SHELL` verbatim (word-split, may carry arguments),
    ///   else `"$SHELL" -il`, else `/bin/sh -i`.
    /// - `kill-session -t NAME` SIGHUPs the recorded process group.
    /// - `kill-server` SIGHUPs every recorded pid and removes the state.
    /// - `list-panes -a -F FORMAT` prints tab-separated
    ///   name/tty/pid/path/command per live session; a
    ///   `<state>/<name>.panemeta` file overrides the last four fields.
    private static let script = #"""
        #!/bin/bash
        # Fake tmux for PedalsDaemonCore unit tests. Not a tmux implementation:
        # just enough of the CLI surface for SessionManager/TmuxConfiguration.
        set -u

        SOCK=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -S) SOCK="$2"; shift 2 ;;
                -f) shift 2 ;;
                *) break ;;
            esac
        done

        CMD="${1:-}"
        STATE="${SOCK}.state"
        LOG="${SOCK}.log"

        # Record every invocation (argv after the global flags, one line).
        if [ -n "$CMD" ]; then
            LINE=""
            for ARG in "$@"; do
                if [ -z "$LINE" ]; then LINE="$ARG"; else LINE="$LINE $ARG"; fi
            done
            echo "$LINE" >> "$LOG"
        fi

        kill_recorded() {
            kill -HUP -- -"$1" 2>/dev/null
            kill -HUP "$1" 2>/dev/null
        }

        remove_session_state() {
            rm -f "$STATE/$1.pid" "$STATE/$1.cwd" "$STATE/$1.cmd" "$STATE/$1.panemeta"
        }

        case "$CMD" in
        new-session)
            shift
            NAME=""
            CWD="$PWD"
            while [ $# -gt 0 ]; do
                case "$1" in
                    -s) NAME="$2"; shift 2 ;;
                    -x|-y) shift 2 ;;
                    -c) CWD="$2"; shift 2 ;;
                    -e) export "$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            [ -n "$NAME" ] || exit 1
            mkdir -p "$STATE"
            cd "$CWD" 2>/dev/null || true
            if [ -n "${FAKE_TMUX_SHELL:-}" ]; then
                # Deliberate word splitting: "/bin/zsh -f" is program + args.
                set -- $FAKE_TMUX_SHELL
            elif [ -n "${SHELL:-}" ]; then
                set -- "$SHELL" -il
            else
                set -- /bin/sh -i
            fi
            # $$ survives exec, so the recorded pid is the shell's pid.
            echo $$ > "$STATE/$NAME.pid"
            pwd > "$STATE/$NAME.cwd"
            basename "$1" > "$STATE/$NAME.cmd"
            exec "$@"
            ;;
        kill-session)
            shift
            NAME=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    -t) NAME="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            if [ -f "$STATE/$NAME.pid" ]; then
                kill_recorded "$(cat "$STATE/$NAME.pid")"
            fi
            remove_session_state "$NAME"
            exit 0
            ;;
        kill-server)
            if [ -d "$STATE" ]; then
                for PIDFILE in "$STATE"/*.pid; do
                    [ -e "$PIDFILE" ] || continue
                    kill_recorded "$(cat "$PIDFILE")"
                done
                rm -rf "$STATE"
            fi
            exit 0
            ;;
        list-panes)
            [ -d "$STATE" ] || exit 0
            for PIDFILE in "$STATE"/*.pid; do
                [ -e "$PIDFILE" ] || continue
                NAME="$(basename "$PIDFILE" .pid)"
                PID="$(cat "$PIDFILE")"
                if ! kill -0 "$PID" 2>/dev/null; then
                    remove_session_state "$NAME"
                    continue
                fi
                META="$STATE/$NAME.panemeta"
                if [ -f "$META" ]; then
                    TTY="$(cut -f1 "$META")"
                    MPID="$(cut -f2 "$META")"
                    PPATH="$(cut -f3 "$META")"
                    PCMD="$(cut -f4- "$META")"
                else
                    TTY="/dev/ttys000"
                    MPID="$PID"
                    PPATH="$(cat "$STATE/$NAME.cwd")"
                    PCMD="$(cat "$STATE/$NAME.cmd")"
                fi
                printf '%s\t%s\t%s\t%s\t%s\n' "$NAME" "$TTY" "$MPID" "$PPATH" "$PCMD"
            done
            exit 0
            ;;
        *)
            echo "fake tmux: unsupported command '$CMD'" >&2
            exit 1
            ;;
        esac
        """# + "\n"
}
