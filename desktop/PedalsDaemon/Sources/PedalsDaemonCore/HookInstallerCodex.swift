import Foundation

/// Codex CLI: sentinel-marked entries merged into `~/.codex/hooks.json`
/// (Claude-style grouped shape) plus the `hooks = true` feature flag in
/// `~/.codex/config.toml`.
///
/// The TOML flag is edited line-based (as supacode does): only the
/// `hooks = true` / legacy `codex_hooks = true` lines inside `[features]` are
/// ever touched; every other line is preserved byte-for-byte.
extension HookInstaller {
    /// Refreshes an existing Pedals-managed Codex installation after the app
    /// updates. It never opts a user into hooks: at least one sentinel-marked
    /// Codex hook must already exist. User-authored hook groups and unrelated
    /// config.toml lines retain the same merge guarantees as a manual
    /// reinstall.
    @discardableResult
    public static func refreshManagedCodexInstallation(
        reporterSource: URL,
        reporterDestination: URL,
        home explicitHome: URL? = nil
    ) throws -> Bool {
        let home = explicitHome ?? defaultHome
        guard try !managedGroupedPairs(path: Codex.hooksPath(home: home)).isEmpty
        else { return false }
        try installReporterBinary(from: reporterSource, to: reporterDestination)
        try Codex.install(reporterPath: reporterDestination.path, home: home)
        return true
    }

    enum Codex {
        static func hooksPath(home: URL) -> String {
            home.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("hooks.json").path
        }

        static func configPath(home: URL) -> String {
            home.appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml").path
        }

        static func entries(reporterPath: String) -> [GroupedHookEntry] {
            [
                ("SessionStart", "session-start", 1),
                ("UserPromptSubmit", "prompt", 1),
                ("PreToolUse", "tool", 1),
                ("PermissionRequest", "ask", 1),
                ("Stop", "stop", 1),
                ("SessionEnd", "session-end", 1),
            ].map { event, reporterEvent, timeout in
                GroupedHookEntry(
                    event: event, matcher: nil,
                    command: reporterCommand(reporterPath, slug: "codex", event: reporterEvent),
                    timeout: timeout
                )
            }
        }

        static func install(reporterPath: String, home: URL) throws {
            try installGrouped(entries: entries(reporterPath: reporterPath), path: hooksPath(home: home))
            try ConfigToml.ensureFlag(path: configPath(home: home))
        }

        static func uninstall(home: URL) throws {
            // Only drop the feature flag when the prune actually removed our
            // entries: a user who enabled hooks for their own hooks.json
            // entries keeps their flag.
            let hadManaged = try !managedGroupedPairs(path: hooksPath(home: home)).isEmpty
            try uninstallGrouped(path: hooksPath(home: home))
            if hadManaged {
                try ConfigToml.removeFlag(path: configPath(home: home))
            }
        }

        static func state(reporterPath: String, home: URL) throws -> State {
            let hooksState = try stateGrouped(
                entries: entries(reporterPath: reporterPath), path: hooksPath(home: home)
            )
            let flags = try ConfigToml.flagState(path: configPath(home: home))
            if hooksState == .installed, flags.hooksTrue, !flags.legacy {
                return .installed
            }
            if hooksState == .notInstalled, !flags.hooksTrue, !flags.legacy {
                return .notInstalled
            }
            return .outdated
        }

        // MARK: - config.toml line editing

        enum ConfigToml {
            /// Reads the file as lines; missing file → nil, non-UTF8 → error.
            private static func readLines(path: String) throws -> [String]? {
                guard let data = FileManager.default.contents(atPath: path) else { return nil }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw InstallerError.malformedSettings(path: path, detail: "not UTF-8 text")
                }
                return text.components(separatedBy: "\n")
            }

            private static func write(lines: [String], path: String) throws {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
            }

            private static func stripComment(_ line: String) -> Substring {
                if let hash = line.firstIndex(of: "#") { return line[..<hash] }
                return line[...]
            }

            /// `[features]`, tolerating spacing (`[ features ]`) and trailing
            /// comments.
            static func isFeaturesHeader(_ line: String) -> Bool {
                let trimmed = stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[")
                else { return false }
                let inner = trimmed.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return inner == "features"
            }

            static func isSectionHeader(_ line: String) -> Bool {
                stripComment(line).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
            }

            private static func assignmentKey(_ line: String) -> String? {
                let noComment = stripComment(line)
                guard let equals = noComment.firstIndex(of: "=") else { return nil }
                let key = noComment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                return key.isEmpty ? nil : key
            }

            static func isHooksTrue(_ line: String) -> Bool {
                let noComment = stripComment(line)
                guard let equals = noComment.firstIndex(of: "=") else { return false }
                let key = noComment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = noComment[noComment.index(after: equals)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return key == "hooks" && value == "true"
            }

            private static func isBlank(_ line: String) -> Bool {
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            /// The line range of the `[features]` section body (after the
            /// header, up to the next section header or EOF).
            private static func featuresBody(in lines: [String]) -> (header: Int, body: Range<Int>)? {
                guard let header = lines.firstIndex(where: isFeaturesHeader) else { return nil }
                var end = header + 1
                while end < lines.count, !isSectionHeader(lines[end]) { end += 1 }
                return (header, (header + 1)..<end)
            }

            /// Install side: make `[features]` contain `hooks = true`, strip
            /// any legacy `codex_hooks = ...` line, touch nothing else.
            static func ensureFlag(path: String) throws {
                guard var lines = try readLines(path: path) else {
                    try write(lines: ["[features]", "hooks = true", ""], path: path)
                    return
                }
                if let (_, body) = featuresBody(in: lines) {
                    var newBody: [String] = []
                    var hasTrue = false
                    for line in lines[body] {
                        if assignmentKey(line) == "codex_hooks" { continue }
                        if assignmentKey(line) == "hooks" {
                            if hasTrue { continue } // drop duplicate assignments
                            newBody.append(isHooksTrue(line) ? line : "hooks = true")
                            hasTrue = true
                            continue
                        }
                        newBody.append(line)
                    }
                    if !hasTrue {
                        let insertAt = (newBody.lastIndex { !isBlank($0) }).map { $0 + 1 } ?? 0
                        newBody.insert("hooks = true", at: insertAt)
                    }
                    lines.replaceSubrange(body, with: newBody)
                } else {
                    while let last = lines.last, isBlank(last) { lines.removeLast() }
                    if lines.isEmpty {
                        lines = ["[features]", "hooks = true", ""]
                    } else {
                        lines += ["", "[features]", "hooks = true", ""]
                    }
                }
                try write(lines: lines, path: path)
            }

            /// Uninstall side: drop `hooks = true` lines inside `[features]`;
            /// drop the header too when the section is left entirely blank.
            static func removeFlag(path: String) throws {
                guard var lines = try readLines(path: path) else { return }
                guard let (header, body) = featuresBody(in: lines) else { return }
                let newBody = lines[body].filter { !isHooksTrue($0) }
                if newBody.allSatisfy(isBlank) {
                    lines.removeSubrange(header..<body.upperBound)
                    if header > 0, header - 1 < lines.count, isBlank(lines[header - 1]) {
                        lines.remove(at: header - 1)
                    }
                } else {
                    lines.replaceSubrange(body, with: newBody)
                }
                try write(lines: lines, path: path)
            }

            static func flagState(path: String) throws -> (hooksTrue: Bool, legacy: Bool) {
                guard let lines = try readLines(path: path) else { return (false, false) }
                guard let (_, body) = featuresBody(in: lines) else { return (false, false) }
                let hooksTrue = lines[body].contains(where: isHooksTrue)
                let legacy = lines[body].contains { assignmentKey($0) == "codex_hooks" }
                return (hooksTrue, legacy)
            }
        }
    }
}
