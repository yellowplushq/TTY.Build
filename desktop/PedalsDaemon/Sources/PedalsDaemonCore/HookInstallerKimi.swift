import Foundation

/// Kimi Code: sentinel-marked `[[hooks]]` blocks merged into
/// `~/.kimi-code/config.toml` with a structured line editor (a port of
/// supacode's KimiHookSettingsFileInstaller semantics). A managed block is a
/// `[[hooks]]` table whose `command` value contains the sentinel; it extends
/// to the next `[...]`/`[[...]]` header or EOF. Install drops managed blocks
/// and appends the canonical ones; uninstall only drops. Everything else —
/// including user-authored `[[hooks]]` blocks — is preserved byte-for-byte
/// (modulo CRLF→LF normalization).
extension HookInstaller {
    enum Kimi {
        static func path(home: URL) -> String {
            home.appendingPathComponent(".kimi-code", isDirectory: true)
                .appendingPathComponent("config.toml").path
        }

        /// (kimi event, reporter event, timeout seconds). No matchers in our
        /// set.
        static let events: [(event: String, reporterEvent: String, timeout: Int)] = [
            ("SessionStart", "session-start", 1),
            ("UserPromptSubmit", "prompt", 1),
            ("PreToolUse", "tool", 1),
            ("Notification", "notify", 1),
            ("Stop", "stop", 1),
            ("SessionEnd", "session-end", 1),
        ]

        static func command(reporterPath: String, reporterEvent: String) -> String {
            reporterCommand(reporterPath, slug: "kimi", event: reporterEvent)
        }

        static func canonicalPairs(reporterPath: String) -> Set<String> {
            Set(events.map { event, reporterEvent, _ in
                "\(event)\u{0}\(command(reporterPath: reporterPath, reporterEvent: reporterEvent))"
            })
        }

        static func canonicalBlocks(reporterPath: String) -> [String] {
            events.map { event, reporterEvent, timeout in
                let escaped = escapeDoubleQuoted(
                    command(reporterPath: reporterPath, reporterEvent: reporterEvent)
                )
                return """
                [[hooks]]
                event = "\(event)"
                command = "\(escaped)"
                timeout = \(timeout)
                """
            }
        }

        // MARK: - Lifecycle

        static func install(reporterPath: String, home: URL) throws {
            let path = path(home: home)
            let chunks = try parse(content: readContent(path: path) ?? "")
            var out = joined(keepingUnmanaged: chunks)
            if !out.isEmpty {
                if !out.hasSuffix("\n") { out += "\n" }
                if !out.hasSuffix("\n\n") { out += "\n" }
            }
            out += canonicalBlocks(reporterPath: reporterPath).joined(separator: "\n\n") + "\n"
            try write(content: out, path: path)
        }

        static func uninstall(home: URL) throws {
            let path = path(home: home)
            guard let content = try readContent(path: path) else { return }
            let chunks = try parse(content: content)
            guard chunks.contains(where: { $0.isManagedHooksBlock }) else { return }
            try write(content: joined(keepingUnmanaged: chunks), path: path)
        }

        static func state(reporterPath: String, home: URL) throws -> State {
            guard let content = try readContent(path: path(home: home)) else {
                return .notInstalled
            }
            var found = Set<String>()
            for chunk in try parse(content: content) {
                guard case .hooksBlock(let block) = chunk, block.isManaged else { continue }
                found.insert("\(block.event ?? "")\u{0}\(block.command ?? "")")
            }
            guard !found.isEmpty else { return .notInstalled }
            return found == canonicalPairs(reporterPath: reporterPath) ? .installed : .outdated
        }

        // MARK: - TOML line structure

        struct HooksBlock {
            var lines: [String]
            var event: String?
            var command: String?
            var isManaged: Bool { command?.contains(sentinel) ?? false }
        }

        enum Chunk {
            case plain([String])
            case hooksBlock(HooksBlock)

            var isManagedHooksBlock: Bool {
                if case .hooksBlock(let block) = self { return block.isManaged }
                return false
            }
        }

        /// Missing file → nil; non-UTF8 → typed error; CRLF normalized to LF.
        private static func readContent(path: String) throws -> String? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            guard let text = String(data: data, encoding: .utf8) else {
                throw InstallerError.malformedSettings(path: path, detail: "not UTF-8 text")
            }
            return text.replacingOccurrences(of: "\r\n", with: "\n")
        }

        private static func write(content: String, path: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url, options: .atomic)
        }

        /// `[[hooks]]` at column 0, tolerating inner spacing and a trailing
        /// comment (regex `^\[\[\s*hooks\s*\]\]\s*(#.*)?$`).
        static func isHooksHeader(_ line: String) -> Bool {
            guard line.hasPrefix("[[") else { return false }
            guard let close = line.range(of: "]]") else { return false }
            let name = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            guard name == "hooks" else { return false }
            let rest = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            return rest.isEmpty || rest.hasPrefix("#")
        }

        /// Any `[...]` / `[[...]]` table header terminates a hooks block.
        private static func isAnyHeader(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }

        static func parse(content: String) throws -> [Chunk] {
            guard !content.isEmpty else { return [] }
            let lines = content.components(separatedBy: "\n")
            var chunks: [Chunk] = []
            var plain: [String] = []
            var index = 0
            while index < lines.count {
                let line = lines[index]
                guard isHooksHeader(line) else {
                    plain.append(line)
                    index += 1
                    continue
                }
                if !plain.isEmpty {
                    chunks.append(.plain(plain))
                    plain = []
                }
                var blockLines = [line]
                index += 1
                while index < lines.count, !isAnyHeader(lines[index]) {
                    blockLines.append(lines[index])
                    index += 1
                }
                chunks.append(.hooksBlock(makeBlock(lines: blockLines)))
            }
            if !plain.isEmpty { chunks.append(.plain(plain)) }
            return chunks
        }

        private static func makeBlock(lines: [String]) -> HooksBlock {
            var block = HooksBlock(lines: lines, event: nil, command: nil)
            for line in lines.dropFirst() {
                guard let (key, rawValue) = splitAssignment(line) else { continue }
                switch key {
                case "event": block.event = parseTomlString(rawValue)
                case "command": block.command = parseTomlString(rawValue)
                default: break
                }
            }
            return block
        }

        private static func splitAssignment(_ line: String) -> (key: String, value: String)? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix("#") else { return nil }
            return (key, String(line[line.index(after: equals)...]))
        }

        /// Parses a TOML basic string (`"..."` with `\\ \" \n \r \t` escapes)
        /// or literal string (`'...'`); trailing comments after the closing
        /// quote are ignored.
        static func parseTomlString(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return nil }
            if first == "\"" {
                var result = ""
                var escaped = false
                for character in trimmed.dropFirst() {
                    if escaped {
                        switch character {
                        case "\\": result.append("\\")
                        case "\"": result.append("\"")
                        case "n": result.append("\n")
                        case "r": result.append("\r")
                        case "t": result.append("\t")
                        default: result.append(character)
                        }
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        return result
                    } else {
                        result.append(character)
                    }
                }
                return nil // unterminated
            }
            if first == "'" {
                let body = trimmed.dropFirst()
                guard let close = body.firstIndex(of: "'") else { return nil }
                return String(body[..<close])
            }
            return nil
        }

        /// Reassembles every chunk except managed hooks blocks.
        private static func joined(keepingUnmanaged chunks: [Chunk]) -> String {
            var lines: [String] = []
            for chunk in chunks {
                switch chunk {
                case .plain(let plainLines):
                    lines.append(contentsOf: plainLines)
                case .hooksBlock(let block) where !block.isManaged:
                    lines.append(contentsOf: block.lines)
                case .hooksBlock:
                    break
                }
            }
            return lines.joined(separator: "\n")
        }
    }
}
