import ArgumentParser
import AppKit
import Darwin
import Foundation
import PedalsDaemonCore
import PedalsKit

@main
struct PedalsCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pedals",
        abstract: "Pedals desktop daemon — remote terminal host.",
        subcommands: [
            Serve.self, Ls.self, New.self, Kill.self, Pair.self, Status.self,
            Agents.self, Hooks.self,
        ]
    )
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pedals: \(message)\n".utf8))
    Foundation.exit(1)
}

// MARK: - serve

struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the daemon in the foreground (PTY host + relay connection)."
    )

    @Option(help: "Pedals HTTPS service origin; written to config.json for future runs.")
    var service: String?

    func run() throws {
        let home = PedalsHome()
        if let service {
            guard let url = validServiceURL(service) else {
                fail("--service must be an https:// URL")
            }
            try home.save(config: .init(service: url.absoluteString))
        }

        let daemon: Daemon
        do {
            daemon = try Daemon(home: home)
        } catch {
            fail("\(error)")
        }
        try daemon.start()

        print("pedals daemon started")
        print("  socket:  \(home.socketPath)")
        print("  service:  \(daemon.hostIdentity.computer.serviceURL.absoluteString)")
        print("  computer: \(daemon.hostIdentity.computer.computerID)")
        print("pair from iOS with: pedals pair")

        // Park the main thread; SIGINT/SIGTERM shut down cleanly.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in daemon.suspend() }
        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in daemon.resume() }
        for source in [sigint, sigterm] {
            source.setEventHandler {
                workspaceCenter.removeObserver(sleepObserver)
                workspaceCenter.removeObserver(wakeObserver)
                daemon.shutdown()
                Foundation.exit(0)
            }
            source.resume()
        }
        dispatchMain()
    }
}

// MARK: - socket-backed subcommands

struct Ls: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sessions.")

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "ls"])
        let sessions = reply["sessions"] as? [[String: Any]] ?? []
        let client = reply["client"] as? String ?? "none"
        let service = reply["service"] as? String ?? "?"
        if sessions.isEmpty {
            print("no sessions")
        }
        for session in sessions {
            let id = session["id"] as? Int ?? 0
            let title = session["title"] as? String ?? ""
            let cwd = session["cwd"] as? String ?? ""
            let alive = session["alive"] as? Bool ?? false
            let cols = session["cols"] as? Int ?? 0
            let rows = session["rows"] as? Int ?? 0
            print("[\(id)] \(alive ? "live " : "exited") \(cols)x\(rows)  \(title)  (\(cwd))")
        }
        print("client: \(client)   service: \(service)")
    }
}

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new session.")

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "new"])
        print("created session \(reply["id"] as? Int ?? -1)")
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Close a session.")

    @Argument(help: "Session id (see `pedals ls`).")
    var id: Int

    func run() throws {
        _ = try roundTripOrFail(["cmd": "kill", "id": id])
        print("closed session \(id)")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show relay connection status.")

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "status"])
        print("service:  \(reply["service"] as? String ?? "?") (\(reply["state"] as? String ?? "?"))")
        print("computer: \(reply["computer"] as? String ?? "?")")
        print("client: \(reply["client"] as? String ?? "none")")
        print("uptime: \(Int(reply["uptime"] as? Double ?? 0))s")
    }
}

struct Agents: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dump observed coding-agent sessions as JSON."
    )

    func run() throws {
        let reply = try roundTripOrFail(["cmd": "agents"])
        let list = reply["agents"] as? [Any] ?? []
        let data = try JSONSerialization.data(
            withJSONObject: list,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - hooks

struct Hooks: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage coding-agent activity hooks.",
        subcommands: [HooksInstall.self, HooksUninstall.self, HooksStatus.self]
    )
}

private let hookedAgentSlugs = HookInstaller.HookedAgent.allCases
    .map(\.rawValue).joined(separator: ", ")

private func hookedAgent(_ slug: String) -> HookInstaller.HookedAgent {
    guard let agent = HookInstaller.HookedAgent(rawValue: slug) else {
        fail("unsupported agent \"\(slug)\" (supported: \(hookedAgentSlugs))")
    }
    return agent
}

/// The freshly built reporter next to this executable, for `hooks install`.
private func builtReporterURL() -> URL {
    let executable = Bundle.main.executableURL
        ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return executable.resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .appendingPathComponent("pedals-hook")
}

struct HooksInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Copy the reporter to ~/.pedals/bin and write agent hook settings."
    )

    @Argument(help: "Agent slug (\(HookInstaller.HookedAgent.allCases.map(\.rawValue).joined(separator: "|"))).")
    var agent: String

    func run() throws {
        let agent = hookedAgent(self.agent)
        let home = PedalsHome()
        let source = builtReporterURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            fail("reporter binary not found at \(source.path) — build pedals-hook first")
        }
        do {
            try HookInstaller.installReporterBinary(from: source, to: home.hookReporterURL)
            try HookInstaller.install(for: agent, reporterPath: home.hookReporterURL.path)
        } catch {
            fail("\(error)")
        }
        print("installed \(self.agent) hooks → \(HookInstaller.settingsPath(for: agent))")
        print("reporter: \(home.hookReporterURL.path)")
    }
}

struct HooksUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove pedals-managed hook entries from agent settings."
    )

    @Argument(help: "Agent slug (\(HookInstaller.HookedAgent.allCases.map(\.rawValue).joined(separator: "|"))).")
    var agent: String

    func run() throws {
        let agent = hookedAgent(self.agent)
        do {
            try HookInstaller.uninstall(for: agent)
        } catch {
            fail("\(error)")
        }
        print("removed \(self.agent) hooks from \(HookInstaller.settingsPath(for: agent))")
    }
}

struct HooksStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether pedals-managed hooks are installed."
    )

    @Argument(help: "Agent slug; omit to list every supported agent.")
    var agent: String?

    func run() throws {
        let home = PedalsHome()
        guard let slug = agent else {
            for agent in HookInstaller.HookedAgent.allCases {
                let text: String
                do {
                    text = switch try HookInstaller.state(
                        for: agent, reporterPath: home.hookReporterURL.path
                    ) {
                    case .installed: "installed"
                    case .notInstalled: "not installed"
                    case .outdated: "outdated"
                    }
                } catch {
                    text = "error: \(error)"
                }
                let padded = agent.rawValue.padding(
                    toLength: 10, withPad: " ", startingAt: 0
                )
                print("\(padded) \(text)")
            }
            return
        }
        let agent = hookedAgent(slug)
        let state: HookInstaller.State
        do {
            state = try HookInstaller.state(
                for: agent, reporterPath: home.hookReporterURL.path
            )
        } catch {
            fail("\(error)")
        }
        switch state {
        case .installed: print("installed")
        case .notInstalled: print("not installed")
        case .outdated: print("outdated — run `pedals hooks install \(slug)`")
        }
    }
}

struct Pair: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a 15-minute iPhone pairing code."
    )

    @Flag(help: "Register a fresh computer identity and E2EE secret.")
    var reset = false

    @Option(help: "Pedals HTTPS service origin; written to config.json for future runs.")
    var service: String?

    func run() throws {
        let home = PedalsHome()
        if let service {
            guard let url = validServiceURL(service) else {
                fail("--service must be an https:// URL")
            }
            try home.save(config: .init(service: url.absoluteString))
        }

        let code = try PairCommandResolver.resolve(
            socketPath: home.socketPath,
            reset: reset,
            offline: {
                throw ValidationError(
                    "The Pedals daemon must be running while a pairing code is active. "
                        + "Start it with `pedals serve`, then run this command again."
                )
            }
        )

        let pairingCode = try PairingCode(code)
        print("Pairing code: \(pairingCode.formatted)")
        print("Expires in 15 minutes. Keep the pairing page open until the iPhone connects.")
    }
}

private func validServiceURL(_ value: String) -> URL? {
    guard let url = URL(string: value),
          url.host != nil, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil
    else { return nil }
    let scheme = url.scheme?.lowercased()
    let host = url.host!.lowercased()
    guard scheme == "https"
        || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { return nil }
    return url
}

// MARK: - helpers

private func roundTripOrFail(_ request: [String: Any]) throws -> [String: Any] {
    let home = PedalsHome()
    let reply: [String: Any]
    do {
        reply = try ControlClient.roundTrip(socketPath: home.socketPath, request: request)
    } catch {
        fail("\(error)")
    }
    guard reply["ok"] as? Bool == true else {
        fail(reply["err"] as? String ?? "daemon reported an error")
    }
    return reply
}
