import Foundation

/// Grok CLI: a whole file TTYBuild owns at `~/.grok/hooks/ttybuild.json` in the
/// Claude-style grouped shape (Grok globs that directory, so this deviates
/// from supacode's settings merge — simpler and it cannot touch user files).
///
/// Grok spawns hooks without the terminal environment, so every entry carries
/// an `env` map forwarding `TTYBUILD_HOME`; the reporter derives everything else
/// itself.
extension HookInstaller {
    enum Grok {
        static func path(home: URL) -> String {
            home.appendingPathComponent(".grok", isDirectory: true)
                .appendingPathComponent("hooks", isDirectory: true)
                .appendingPathComponent("ttybuild.json").path
        }

        static func entries(reporterPath: String) -> [GroupedHookEntry] {
            let events: [(event: String, matcher: String?, reporterEvent: String, timeout: Int)] = [
                ("SessionStart", nil, "session-start", 1),
                ("UserPromptSubmit", nil, "prompt", 1),
                ("PreToolUse", "", "tool", 1),
                ("Notification", "", "notify", 1),
                ("Stop", nil, "stop", 1),
                ("SessionEnd", "", "session-end", 1),
            ]
            return events.map { event, matcher, reporterEvent, timeout in
                GroupedHookEntry(
                    event: event, matcher: matcher,
                    command: reporterCommand(reporterPath, slug: "grok", event: reporterEvent),
                    timeout: timeout,
                    env: ["TTYBUILD_HOME": "${TTYBUILD_HOME}"]
                )
            }
        }

        static func canonicalData(reporterPath: String) -> Data {
            let root = groupedRoot(entries: entries(reporterPath: reporterPath))
            var data = (try? serializeSettings(root)) ?? Data()
            data.append(0x0A)
            return data
        }

        static func install(reporterPath: String, home: URL) throws {
            try OwnedFile.install(
                canonical: canonicalData(reporterPath: reporterPath),
                path: path(home: home), marker: sentinel
            )
        }

        static func uninstall(home: URL) throws {
            try OwnedFile.uninstall(path: path(home: home), marker: sentinel)
        }

        /// Byte-compare: a hand-edited file — including one whose entries
        /// lost the `env` map — reads as `.outdated` while the sentinel is
        /// still present.
        static func state(reporterPath: String, home: URL) -> State {
            OwnedFile.state(
                canonical: canonicalData(reporterPath: reporterPath),
                path: path(home: home), marker: sentinel
            )
        }
    }
}
