import Foundation

/// Kiro CLI: flat hook entries merged into `~/.kiro/agents/kiro_default.json`
/// — `{"hooks": {"<event>": [{"command": "...", "timeout_ms": N}]}}`, no
/// type/matcher wrapper, millisecond timeouts.
///
/// Creating that file when it does not exist overrides Kiro's built-in
/// default agent, so a fresh install first probes `kiro-cli --version`
/// through the user's login shell (major version 2 required) and then writes
/// supacode's known-good default agent config before merging. The probe is
/// skipped when the file already exists; tests inject a fake probe.
extension HookInstaller {
    enum Kiro {
        static func path(home: URL) -> String {
            home.appendingPathComponent(".kiro", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
                .appendingPathComponent("kiro_default.json").path
        }

        /// (kiro event, reporter event, timeout in milliseconds).
        static let events: [(event: String, reporterEvent: String, timeoutMs: Int)] = [
            ("agentSpawn", "session-start", 1000),
            ("userPromptSubmit", "prompt", 1000),
            ("stop", "stop", 1000),
        ]

        static func command(reporterPath: String, reporterEvent: String) -> String {
            reporterCommand(reporterPath, slug: "kiro", event: reporterEvent)
        }

        /// Supacode's known-good default agent config, written before the
        /// first merge so we never present Kiro an agent with no tools.
        static var defaultConfig: [String: Any] { [
            "name": "kiro_default",
            "tools": ["*"],
            "resources": [
                "file://AGENTS.md",
                "file://README.md",
                "skill://~/.kiro/skills/**/SKILL.md",
                "skill://~/.kiro/steering/**/*.md",
            ],
            "useLegacyMcpJson": true,
            "hooks": [String: Any](),
        ] }

        // MARK: - Lifecycle

        static func install(reporterPath: String, home: URL, probe: KiroProbe) throws {
            let path = path(home: home)
            var root: [String: Any]
            if FileManager.default.fileExists(atPath: path) {
                root = try readSettings(path: path)
            } else {
                try checkCLI(probe: probe)
                root = defaultConfig
            }
            var hooks = try hooksObject(of: root, path: path) ?? [:]
            removeManagedFlatEntries(&hooks)
            for (event, reporterEvent, timeoutMs) in events {
                var entries: [Any]
                if let existing = hooks[event] {
                    guard let array = existing as? [Any] else {
                        throw InstallerError.malformedSettings(
                            path: path, detail: "\"hooks.\(event)\" is not an array"
                        )
                    }
                    entries = array
                } else {
                    entries = []
                }
                entries.append([
                    "command": command(reporterPath: reporterPath, reporterEvent: reporterEvent),
                    "timeout_ms": timeoutMs,
                ] as [String: Any])
                hooks[event] = entries
            }
            root["hooks"] = hooks
            try writeSettings(root, path: path)
        }

        static func uninstall(home: URL) throws {
            let path = path(home: home)
            guard FileManager.default.fileExists(atPath: path) else { return }
            var root = try readSettings(path: path)
            guard var hooks = try hooksObject(of: root, path: path) else { return }
            removeManagedFlatEntries(&hooks)
            // Keep `"hooks": {}` even when emptied: it is part of the default
            // agent config shape.
            root["hooks"] = hooks
            try writeSettings(root, path: path)
        }

        static func state(reporterPath: String, home: URL) throws -> State {
            let path = path(home: home)
            guard FileManager.default.fileExists(atPath: path) else { return .notInstalled }
            let root = try readSettings(path: path)
            guard let hooks = try hooksObject(of: root, path: path) else { return .notInstalled }
            var found = Set<String>()
            for (event, value) in hooks {
                guard let entries = value as? [Any] else { continue }
                for case let entry as [String: Any] in entries {
                    if let command = entry["command"] as? String, command.contains(sentinel) {
                        found.insert("\(event)\u{0}\(command)")
                    }
                }
            }
            guard !found.isEmpty else { return .notInstalled }
            let canonical = Set(events.map { event, reporterEvent, _ in
                "\(event)\u{0}\(command(reporterPath: reporterPath, reporterEvent: reporterEvent))"
            })
            return found == canonical ? .installed : .outdated
        }

        /// Drops every sentinel-marked flat entry, pruning emptied event
        /// arrays.
        private static func removeManagedFlatEntries(_ hooks: inout [String: Any]) {
            for (event, value) in hooks {
                guard let entries = value as? [Any] else { continue }
                let kept = entries.filter { entry in
                    guard let entryObject = entry as? [String: Any],
                          let command = entryObject["command"] as? String
                    else { return true }
                    return !command.contains(sentinel)
                }
                if kept.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = kept
                }
            }
        }

        // MARK: - Version probe

        /// Requires a working `kiro-cli` with major version 2 before we dare
        /// override Kiro's built-in default agent.
        static func checkCLI(probe: KiroProbe) throws {
            let output: KiroProbeOutput
            do {
                output = try probe()
            } catch let error as InstallerError {
                throw error
            } catch {
                throw InstallerError.kiroCLIUnavailable(detail: "\(error)")
            }
            if output.status == 127 {
                throw InstallerError.kiroCLIUnavailable(
                    detail: "kiro-cli not found on the login-shell PATH (exit 127)"
                )
            }
            guard let version = firstDottedVersion(in: output.standardOutput)
                ?? firstDottedVersion(in: output.standardError)
            else {
                throw InstallerError.kiroCLIUnavailable(
                    detail: "`kiro-cli --version` printed no version number"
                )
            }
            guard version.split(separator: ".").first == "2" else {
                throw InstallerError.unsupportedKiroVersion(found: version)
            }
        }

        /// First dotted digit token (`2.3.0` in `kiro-cli 2.3.0 (abc)`).
        static func firstDottedVersion(in text: String) -> String? {
            for rawToken in text.split(whereSeparator: \.isWhitespace) {
                let token = rawToken.trimmingCharacters(
                    in: CharacterSet(charactersIn: "()[]v,;")
                )
                let parts = token.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count >= 2,
                      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
                else { continue }
                return token
            }
            return nil
        }

        /// Runs `kiro-cli --version` in the user's login shell with a 5 s
        /// SIGTERM / +2 s SIGKILL timeout. Never invoked from tests.
        static func defaultProbe() throws -> KiroProbeOutput {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-c", "kiro-cli --version"]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw InstallerError.kiroCLIUnavailable(
                    detail: "could not launch \(shell): \(error)"
                )
            }
            let terminateAfter = Date().addingTimeInterval(5)
            while process.isRunning, Date() < terminateAfter {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                let killAfter = Date().addingTimeInterval(2)
                while process.isRunning, Date() < killAfter {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return KiroProbeOutput(
                status: process.terminationStatus,
                standardOutput: String(decoding: outData, as: UTF8.self),
                standardError: String(decoding: errData, as: UTF8.self)
            )
        }
    }
}
