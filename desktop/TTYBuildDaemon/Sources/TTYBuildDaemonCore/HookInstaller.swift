import Foundation

/// Writes (and removes) the ttybuild-hook reporter entries in a coding agent's
/// hook settings (docs/AGENT_MONITORING_DESIGN.md §3). AppKit-free: the menu
/// bar app's "Coding Agents" panel calls this directly, as does `ttybuild hooks`.
///
/// Ownership rule: everything TTYBuild writes is marked. Shell-command hook
/// entries carry the trailing `# ttybuild-managed-hook` sentinel in the command
/// string; generated plugin files carry a format-appropriate marker line.
/// Install and uninstall only ever touch marked entries/files; user content is
/// preserved byte-for-byte (modulo re-serialization of merged JSON files).
///
/// Per-agent installers live in the sibling HookInstaller*.swift files; this
/// file holds the public facade, the Claude installer, and the shared plumbing
/// (grouped-JSON merge, owned-file lifecycle).
public enum HookInstaller {
    public enum HookedAgent: String, CaseIterable, Sendable {
        case claude
        case codex
        case copilot
        case grok
        case kimi
        case kiro
        case opencode
        case omp
        case pi
        case hermes
    }

    public enum State: String, Sendable {
        case installed
        case notInstalled
        case outdated
    }

    public enum InstallerError: Error, CustomStringConvertible {
        case malformedSettings(path: String, detail: String)
        /// An install target exists but carries no TTYBuild ownership marker;
        /// refusing to clobber a user file.
        case unownedFile(path: String)
        /// `kiro-cli --version` could not be run or produced no version.
        case kiroCLIUnavailable(detail: String)
        /// Kiro CLI answered with a major version we do not support.
        case unsupportedKiroVersion(found: String)

        public var description: String {
            switch self {
            case .malformedSettings(let path, let detail):
                "hook settings at \(path): \(detail)"
            case .unownedFile(let path):
                "refusing to overwrite \(path): it exists but was not written by tty.build"
            case .kiroCLIUnavailable(let detail):
                "Kiro CLI unavailable: \(detail)"
            case .unsupportedKiroVersion(let found):
                "Kiro CLI version \(found) is unsupported (tty.build needs 2.x)"
            }
        }
    }

    /// Trailing marker that makes a shell-command hook entry ours.
    public static let sentinel = "# ttybuild-managed-hook"

    /// Probe result for `kiro-cli --version` (injectable for tests).
    public struct KiroProbeOutput: Sendable {
        public let status: Int32
        public let standardOutput: String
        public let standardError: String

        public init(status: Int32, standardOutput: String, standardError: String) {
            self.status = status
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    public typealias KiroProbe = () throws -> KiroProbeOutput

    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The canonical reporter invocation for one agent event, ending with the
    /// ownership sentinel. Claude passes no `--event`: its reporter reads
    /// `hook_event_name` from stdin.
    static func reporterCommand(
        _ reporterPath: String, slug: String, event: String? = nil
    ) -> String {
        if let event {
            return "\(reporterPath) \(slug) --event \(event) \(sentinel)"
        }
        return "\(reporterPath) \(slug) \(sentinel)"
    }

    // MARK: - Claude

    /// Claude hook events TTYBuild subscribes to. A nil matcher means the event
    /// takes no matcher; "" subscribes to every tool/notification. PreToolUse
    /// is a single catch-all entry — the reporter distinguishes ask-tools
    /// itself from its stdin.
    private static let claudeEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", ""),
        ("Notification", ""),
        ("Stop", nil),
        ("SessionEnd", ""),
        ("PreCompact", nil),
    ]

    private static func claudeEntries(reporterPath: String) -> [GroupedHookEntry] {
        claudeEvents.map { event, matcher in
            GroupedHookEntry(
                event: event, matcher: matcher,
                command: reporterCommand(reporterPath, slug: "claude"), timeout: 1
            )
        }
    }

    /// The primary file (or directory, for hermes) an agent's installer
    /// writes. Claude honors `$CLAUDE_CONFIG_DIR`; codex additionally edits
    /// `config.toml` next to the returned path.
    public static func settingsPath(
        for agent: HookedAgent,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) -> String {
        let home = home ?? defaultHome
        switch agent {
        case .claude:
            if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                return URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent("settings.json").path
            }
            return home.appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json").path
        case .codex: return Codex.hooksPath(home: home)
        case .copilot: return Copilot.path(home: home)
        case .grok: return Grok.path(home: home)
        case .kimi: return Kimi.path(home: home)
        case .kiro: return Kiro.path(home: home)
        case .opencode: return OpenCode.path(home: home)
        case .omp: return PiFamily.path(home: home, agent: .omp)
        case .pi: return PiFamily.path(home: home, agent: .pi)
        case .hermes: return Hermes.directory(home: home).path
        }
    }

    // MARK: - Install / uninstall / state

    /// Removes every TTYBuild-marked entry/file, then writes the canonical set
    /// pointing at `reporterPath`. Re-running is idempotent; user content is
    /// preserved. `settingsPath` overrides the target file for claude only;
    /// `home` rebases every agent's dot-directory (tests). `kiroProbe` stands
    /// in for `kiro-cli --version` (tests must inject it).
    public static func install(
        for agent: HookedAgent = .claude,
        reporterPath: String,
        home: URL? = nil,
        settingsPath: String? = nil,
        kiroProbe: KiroProbe? = nil
    ) throws {
        let home = home ?? defaultHome
        switch agent {
        case .claude:
            try installGrouped(
                entries: claudeEntries(reporterPath: reporterPath),
                path: settingsPath ?? Self.settingsPath(for: .claude, home: home)
            )
        case .codex:
            try Codex.install(reporterPath: reporterPath, home: home)
        case .copilot:
            try Copilot.install(reporterPath: reporterPath, home: home)
        case .grok:
            try Grok.install(reporterPath: reporterPath, home: home)
        case .kimi:
            try Kimi.install(reporterPath: reporterPath, home: home)
        case .kiro:
            try Kiro.install(
                reporterPath: reporterPath, home: home,
                probe: kiroProbe ?? Kiro.defaultProbe
            )
        case .opencode:
            try OpenCode.install(reporterPath: reporterPath, home: home)
        case .omp:
            try PiFamily.install(reporterPath: reporterPath, home: home, agent: .omp)
        case .pi:
            try PiFamily.install(reporterPath: reporterPath, home: home, agent: .pi)
        case .hermes:
            try Hermes.install(reporterPath: reporterPath, home: home)
        }
    }

    /// Removes every TTYBuild-marked entry/file (pruning emptied containers) and
    /// leaves everything else alone. Missing files are a no-op.
    public static func uninstall(
        for agent: HookedAgent = .claude,
        home: URL? = nil,
        settingsPath: String? = nil
    ) throws {
        let home = home ?? defaultHome
        switch agent {
        case .claude:
            try uninstallGrouped(
                path: settingsPath ?? Self.settingsPath(for: .claude, home: home)
            )
        case .codex: try Codex.uninstall(home: home)
        case .copilot: try Copilot.uninstall(home: home)
        case .grok: try Grok.uninstall(home: home)
        case .kimi: try Kimi.uninstall(home: home)
        case .kiro: try Kiro.uninstall(home: home)
        case .opencode: try OpenCode.uninstall(home: home)
        case .omp: try PiFamily.uninstall(home: home, agent: .omp)
        case .pi: try PiFamily.uninstall(home: home, agent: .pi)
        case .hermes: try Hermes.uninstall(home: home)
        }
    }

    /// Compares what is on disk against the canonical install for
    /// `reporterPath`: a moved binary, changed event list, or hand-edited
    /// generated file reads as `.outdated`.
    public static func state(
        for agent: HookedAgent = .claude,
        reporterPath: String,
        home: URL? = nil,
        settingsPath: String? = nil
    ) throws -> State {
        let home = home ?? defaultHome
        switch agent {
        case .claude:
            return try stateGrouped(
                entries: claudeEntries(reporterPath: reporterPath),
                path: settingsPath ?? Self.settingsPath(for: .claude, home: home)
            )
        case .codex: return try Codex.state(reporterPath: reporterPath, home: home)
        case .copilot: return Copilot.state(reporterPath: reporterPath, home: home)
        case .grok: return Grok.state(reporterPath: reporterPath, home: home)
        case .kimi: return try Kimi.state(reporterPath: reporterPath, home: home)
        case .kiro: return try Kiro.state(reporterPath: reporterPath, home: home)
        case .opencode: return OpenCode.state(reporterPath: reporterPath, home: home)
        case .omp: return PiFamily.state(reporterPath: reporterPath, home: home, agent: .omp)
        case .pi: return PiFamily.state(reporterPath: reporterPath, home: home, agent: .pi)
        case .hermes: return Hermes.state(reporterPath: reporterPath, home: home)
        }
    }

    // MARK: - Reporter binary

    /// Copies the built reporter next to the daemon state (0755), replacing
    /// any previous copy atomically so a running hook never sees a torn
    /// binary.
    public static func installReporterBinary(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let staging = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)"
        )
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: source, to: staging)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: staging.path
        )
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    }

    // MARK: - Shared: grouped hook settings (claude/codex JSON, grok shape)

    /// One canonical entry in the Claude-style grouped shape:
    /// `hooks.<Event> = [{matcher?, hooks: [{type, command, timeout, env?}]}]`.
    struct GroupedHookEntry {
        let event: String
        let matcher: String?
        let command: String
        let timeout: Int
        var env: [String: String]?

        init(
            event: String, matcher: String?, command: String, timeout: Int,
            env: [String: String]? = nil
        ) {
            self.event = event
            self.matcher = matcher
            self.command = command
            self.timeout = timeout
            self.env = env
        }

        /// `{matcher?, hooks: [{type, command, timeout, env?}]}`.
        var groupObject: [String: Any] {
            var entry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": timeout,
            ]
            if let env { entry["env"] = env }
            var group: [String: Any] = ["hooks": [entry]]
            if let matcher { group["matcher"] = matcher }
            return group
        }
    }

    /// Builds a fresh `{"hooks": {...}}` root holding exactly `entries`
    /// (grok's whole-file shape).
    static func groupedRoot(entries: [GroupedHookEntry]) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for entry in entries {
            var groups = hooks[entry.event] as? [Any] ?? []
            groups.append(entry.groupObject)
            hooks[entry.event] = groups
        }
        return ["hooks": hooks]
    }

    /// Removes every sentinel-marked entry, then appends `entries`.
    /// Re-running is idempotent; other settings keys are preserved.
    static func installGrouped(entries: [GroupedHookEntry], path: String) throws {
        var root = try readSettings(path: path)
        var hooks = try hooksObject(of: root, path: path) ?? [:]
        removeManagedGroupedEntries(&hooks)

        for entry in entries {
            var groups: [Any]
            if let existing = hooks[entry.event] {
                guard let array = existing as? [Any] else {
                    throw InstallerError.malformedSettings(
                        path: path, detail: "\"hooks.\(entry.event)\" is not an array"
                    )
                }
                groups = array
            } else {
                groups = []
            }
            groups.append(entry.groupObject)
            hooks[entry.event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root, path: path)
    }

    /// Removes every sentinel-marked entry (pruning emptied arrays/objects)
    /// and leaves everything else alone. Missing file is a no-op.
    static func uninstallGrouped(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var root = try readSettings(path: path)
        guard var hooks = try hooksObject(of: root, path: path) else { return }
        removeManagedGroupedEntries(&hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        try writeSettings(root, path: path)
    }

    /// The `event\0command` pairs of every sentinel-marked entry on disk.
    /// Missing/hookless file reads as the empty set.
    static func managedGroupedPairs(path: String) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let root = try readSettings(path: path)
        guard let hooks = try hooksObject(of: root, path: path) else { return [] }
        var found = Set<String>()
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            for case let group as [String: Any] in groups {
                guard let entries = group["hooks"] as? [Any] else { continue }
                for case let entry as [String: Any] in entries {
                    if let command = entry["command"] as? String, command.contains(sentinel) {
                        found.insert("\(event)\u{0}\(command)")
                    }
                }
            }
        }
        return found
    }

    /// Set-compares the sentinel entries found on disk against `entries`:
    /// a moved binary or changed event list reads as `.outdated`.
    static func stateGrouped(entries: [GroupedHookEntry], path: String) throws -> State {
        let found = try managedGroupedPairs(path: path)
        guard !found.isEmpty else { return .notInstalled }
        let canonical = Set(entries.map { "\($0.event)\u{0}\($0.command)" })
        return found == canonical ? .installed : .outdated
    }

    // MARK: - Shared: settings JSON plumbing

    /// Missing file → empty object. Unparseable or non-object JSON is an
    /// error: never clobber a file we cannot faithfully rewrite.
    static func readSettings(path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw InstallerError.malformedSettings(
                path: path, detail: "not a JSON object"
            )
        }
        return object
    }

    /// nil when "hooks" is absent; error when present but not an object.
    static func hooksObject(
        of root: [String: Any], path: String
    ) throws -> [String: Any]? {
        guard let value = root["hooks"] else { return nil }
        guard let object = value as? [String: Any] else {
            throw InstallerError.malformedSettings(
                path: path, detail: "\"hooks\" is not an object"
            )
        }
        return object
    }

    /// Drops every sentinel-marked command entry anywhere under `hooks`,
    /// pruning matcher groups and event arrays emptied by the removal.
    private static func removeManagedGroupedEntries(_ hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var keptGroups: [Any] = []
            for group in groups {
                guard var groupObject = group as? [String: Any],
                      let entries = groupObject["hooks"] as? [Any]
                else {
                    keptGroups.append(group)
                    continue
                }
                let kept = entries.filter { entry in
                    guard let entryObject = entry as? [String: Any],
                          let command = entryObject["command"] as? String
                    else { return true }
                    return !command.contains(sentinel)
                }
                if kept.isEmpty { continue } // prune the emptied group
                groupObject["hooks"] = kept
                keptGroups.append(groupObject)
            }
            if keptGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = keptGroups
            }
        }
    }

    static func writeSettings(_ root: [String: Any], path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try serializeSettings(root).write(to: url, options: .atomic)
    }

    static func serializeSettings(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Shared: whole files owned by TTYBuild (copilot/grok/plugins)

    /// Lifecycle for a generated file TTYBuild owns outright: install refuses to
    /// clobber a file that lacks `marker`, uninstall deletes only marked
    /// files, state is a byte-compare against the canonical content.
    enum OwnedFile {
        static func install(canonical: Data, path: String, marker: String) throws {
            let manager = FileManager.default
            if let existing = manager.contents(atPath: path),
               !contains(existing, marker: marker)
            {
                throw InstallerError.unownedFile(path: path)
            }
            let url = URL(fileURLWithPath: path)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try canonical.write(to: url, options: .atomic)
        }

        static func uninstall(path: String, marker: String) throws {
            guard let existing = FileManager.default.contents(atPath: path) else { return }
            guard contains(existing, marker: marker) else { return }
            try FileManager.default.removeItem(atPath: path)
        }

        static func state(canonical: Data, path: String, marker: String) -> State {
            guard let existing = FileManager.default.contents(atPath: path) else {
                return .notInstalled
            }
            if existing == canonical { return .installed }
            return contains(existing, marker: marker) ? .outdated : .notInstalled
        }

        static func contains(_ data: Data, marker: String) -> Bool {
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains(marker)
        }
    }

    /// Escapes a string for embedding in a double-quoted JS/TS/Python/TOML
    /// literal (backslash and double-quote, the shared minimum).
    static func escapeDoubleQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
