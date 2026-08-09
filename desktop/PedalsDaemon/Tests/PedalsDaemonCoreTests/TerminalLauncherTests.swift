import Foundation
import XCTest

@testable import PedalsDaemonCore

/// Detection and ranking of the "Open in Terminal" candidates, driven by an
/// injected `Probe`. No app is ever launched here.
final class TerminalLauncherTests: XCTestCase {
    private func probe(
        installed: Set<String>,
        running: Set<String> = [],
        lastUsed: [String: Date] = [:]
    ) -> TerminalLauncher.Probe {
        TerminalLauncher.Probe(
            appURL: { bundleID in
                installed.contains(bundleID)
                    ? URL(fileURLWithPath: "/Applications/\(bundleID).app")
                    : nil
            },
            runningBundleIDs: { running },
            lastUsedDate: { url in
                lastUsed[url.deletingPathExtension().lastPathComponent]
            }
        )
    }

    private func terminal(_ bundleID: String) -> TerminalLauncher.Terminal {
        guard let terminal = TerminalLauncher.knownTerminals
            .first(where: { $0.bundleID == bundleID })
        else {
            preconditionFailure("unknown terminal \(bundleID)")
        }
        return terminal
    }

    private func rankedBundleIDs(
        _ probe: TerminalLauncher.Probe
    ) -> [String] {
        TerminalLauncher.ranked(probe: probe).map(\.bundleID)
    }

    func testInstalledFiltersToKnownPresentTerminals() {
        let probe = probe(installed: [
            "com.apple.Terminal",
            "net.kovidgoyal.kitty",
            "com.example.unknown", // not a known terminal: never surfaces
        ])
        XCTAssertEqual(
            TerminalLauncher.installed(probe: probe).map(\.bundleID),
            ["com.apple.Terminal", "net.kovidgoyal.kitty"]
        )
    }

    func testRankedPutsRunningTerminalsFirstEvenWithoutUsageHistory() {
        let probe = probe(
            installed: [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "net.kovidgoyal.kitty",
            ],
            running: ["net.kovidgoyal.kitty"],
            lastUsed: ["com.googlecode.iterm2": Date()]
        )
        XCTAssertEqual(rankedBundleIDs(probe).first, "net.kovidgoyal.kitty")
    }

    func testRankedOrdersByLastUsedDescendingWithinAGroup() {
        let now = Date()
        let probe = probe(
            installed: [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "net.kovidgoyal.kitty",
            ],
            lastUsed: [
                "com.apple.Terminal": now.addingTimeInterval(-3600),
                "com.googlecode.iterm2": now,
            ]
        )
        // Most recently used first; the terminal with no usage record sorts
        // last.
        XCTAssertEqual(
            rankedBundleIDs(probe),
            ["com.googlecode.iterm2", "com.apple.Terminal", "net.kovidgoyal.kitty"]
        )
    }

    func testRankedTiebreaksOnNameWhenNothingHasUsageData() {
        let probe = probe(installed: [
            "net.kovidgoyal.kitty",
            "com.googlecode.iterm2",
            "org.alacritty",
        ])
        XCTAssertEqual(
            rankedBundleIDs(probe),
            ["org.alacritty", "com.googlecode.iterm2", "net.kovidgoyal.kitty"]
        )
    }

    func testRankedExcludesTerminalsThatAreNotInstalled() {
        let probe = probe(
            installed: ["com.apple.Terminal"],
            running: ["com.mitchellh.ghostty"]
        )
        XCTAssertEqual(rankedBundleIDs(probe), ["com.apple.Terminal"])
    }

    func testOpenOnMissingCLITerminalThrowsNotInstalledWithoutSpawning() {
        XCTAssertThrowsError(
            try TerminalLauncher.open(
                command: "echo hi",
                terminal: terminal("net.kovidgoyal.kitty"),
                probe: probe(installed: [])
            )
        ) { error in
            guard case TerminalLauncher.LaunchError.notInstalled(let name) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(name, "kitty")
        }
    }
}
