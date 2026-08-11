import Darwin
import Foundation

/// Locates the agent process inside the reporter's ancestor lineage.
///
/// The reporter knows which agent invoked it (its own slug argument), so it —
/// not the daemon — is the right place to say which ancestor pid is the agent.
/// Matching is argv-based: the agent CLI may run under a generic runtime
/// (`node`, `bun`, `python3`, a shell), whose kernel `p_comm` says nothing,
/// while its argv still names the launched script. The daemon keeps its old
/// first-non-shell heuristic only as a fallback for reporters older than this
/// field.
public enum AgentProcessLocator {
    /// Process basenames that may run an agent for a given slug. Mirrors the
    /// executables and rename aliases the agents actually ship with.
    static func aliases(for slug: String) -> Set<String> {
        switch slug {
        case "claude": ["claude", "claude-code"]
        case "codex": ["codex"]
        case "copilot": ["copilot", "github-copilot", "ghcs"]
        case "grok": ["grok", "grok-build"]
        case "kimi": ["kimi", "kimi-code"]
        case "kiro": ["kiro", "kiro-cli"]
        case "opencode": ["opencode", "opencode2"]
        case "omp": ["omp"]
        case "pi": ["pi"]
        case "hermes": ["hermes", "hermes-agent"]
        default: [slug]
        }
    }

    /// Generic runtimes and shells whose `p_comm`/argv0 never identifies the
    /// agent by itself; for these, the launched script (first non-flag
    /// argument) carries the identity.
    static let runtimes: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "login", "env",
        "node", "bun", "deno",
    ]

    static func isRuntime(_ name: String) -> Bool {
        let normalized = normalize(name)
        if runtimes.contains(normalized) { return true }
        // python, python3, python3.12, …
        if normalized == "python" { return true }
        if let rest = normalized.range(of: "python").flatMap({ range in
            range.lowerBound == normalized.startIndex
                ? String(normalized[range.upperBound...]) : nil
        }) {
            return !rest.isEmpty && rest.allSatisfy { $0.isNumber || $0 == "." }
        }
        return false
    }

    /// Walks the lineage from the reporter outward and returns the first
    /// ancestor whose identity (comm or argv) matches the slug's aliases —
    /// the nearest such ancestor is the agent that spawned the hook. Returns
    /// nil when nothing matches; callers then keep their legacy fallbacks.
    public static func locate(
        slug: String, lineage: [LineageEntry],
        argvProvider: (pid_t) -> [String]? = processArgv
    ) -> pid_t? {
        let names = aliases(for: slug)
        for entry in lineage where entry.pid > 0 {
            if names.contains(normalize(entry.name)) { return entry.pid }
            guard let argv = argvProvider(entry.pid), !argv.isEmpty else { continue }
            if let argv0 = argv.first, names.contains(normalize(basename(argv0))) {
                return entry.pid
            }
            // Runtime-wrapped launch: `node …/bin/claude`, `python3 /usr/bin/hermes`.
            if isRuntime(argv[0]) || isRuntime(entry.name) {
                if let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }),
                   names.contains(normalize(basename(script)))
                {
                    return entry.pid
                }
            }
        }
        return nil
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func normalize(_ name: String) -> String {
        var normalized = name.lowercased()
        if normalized.hasPrefix("-") { normalized.removeFirst() } // login-shell argv0
        for suffix in [".exe", ".cmd", ".js", ".mjs", ".cjs", ".py", ".ts"] {
            if normalized.hasSuffix(suffix) {
                normalized.removeLast(suffix.count)
                break
            }
        }
        return normalized
    }

    /// Full argv of a same-uid process via `KERN_PROCARGS2`. Returns nil when
    /// the kernel refuses (foreign uid, exited pid) or the buffer is
    /// malformed; identification then falls back to `p_comm`.
    public static func processArgv(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }
        var offset = MemoryLayout<Int32>.size
        // Skip the exec path cstring and its trailing NUL padding.
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }

        var argv: [String] = []
        var current: [UInt8] = []
        while offset < size, argv.count < Int(argc) {
            let byte = buffer[offset]
            if byte == 0 {
                argv.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            offset += 1
        }
        return argv.isEmpty ? nil : argv
    }
}
