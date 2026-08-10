import Foundation
import XCTest

@testable import TTYBuildDaemonCore

/// RemoteManagement against a temp agent home: state listing, install,
/// uninstall, and error paths — the same operations RelayHostClient performs
/// for `hooks-status` / `hook-install` / `hook-uninstall` ctl requests.
final class RemoteManagementTests: XCTestCase {
    private var directory: URL!
    private var agentHome: URL!
    private var reporterSource: URL!
    private var reporterDestination: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttybuild-remote-\(UUID().uuidString)", isDirectory: true)
        agentHome = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: agentHome, withIntermediateDirectories: true
        )
        reporterSource = directory.appendingPathComponent("ttybuild-hook-src")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: reporterSource)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: reporterSource.path
        )
        reporterDestination = directory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("ttybuild-hook")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testHookStatesListsEveryAgentAsNotInstalled() {
        let states = RemoteManagement.hookStates(
            reporterPath: reporterDestination.path, agentHome: agentHome
        )
        XCTAssertEqual(
            Set(states.map(\.agent)),
            Set(HookInstaller.HookedAgent.allCases.map(\.rawValue))
        )
        for entry in states {
            XCTAssertTrue(
                ["notInstalled", "unknown"].contains(entry.state),
                "\(entry.agent) reported \(entry.state) on an empty home"
            )
        }
    }

    func testInstallThenUninstallClaudeRoundTrip() throws {
        try RemoteManagement.installHook(
            agent: "claude",
            reporterDestination: reporterDestination,
            reporterSource: reporterSource,
            agentHome: agentHome
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: reporterDestination.path),
            "install must refresh the shared reporter binary"
        )
        var states = RemoteManagement.hookStates(
            reporterPath: reporterDestination.path, agentHome: agentHome
        )
        XCTAssertEqual(
            states.first(where: { $0.agent == "claude" })?.state, "installed"
        )

        try RemoteManagement.uninstallHook(agent: "claude", agentHome: agentHome)
        states = RemoteManagement.hookStates(
            reporterPath: reporterDestination.path, agentHome: agentHome
        )
        XCTAssertEqual(
            states.first(where: { $0.agent == "claude" })?.state, "notInstalled"
        )
    }

    func testInstallRejectsUnknownAgent() {
        XCTAssertThrowsError(
            try RemoteManagement.installHook(
                agent: "nope",
                reporterDestination: reporterDestination,
                reporterSource: reporterSource,
                agentHome: agentHome
            )
        ) { error in
            XCTAssertEqual(
                (error as? RemoteManagement.RemoteError)?.description,
                RemoteManagement.RemoteError.unknownAgent("nope").description
            )
        }
    }

    func testInstallFailsWithoutReporterSource() {
        XCTAssertThrowsError(
            try RemoteManagement.installHook(
                agent: "claude",
                reporterDestination: reporterDestination,
                reporterSource: nil,
                agentHome: agentHome
            )
        ) { error in
            guard case RemoteManagement.RemoteError.reporterMissing = error else {
                return XCTFail("expected reporterMissing, got \(error)")
            }
        }
    }

    func testUpdateStatusInfoMarksInstallable() {
        let status = RemoteManagement.UpdateStatus(
            current: "1.5.0", latest: "1.6.0", updateAvailable: true
        )
        let info = status.info
        XCTAssertEqual(info.current, "1.5.0")
        XCTAssertEqual(info.latest, "1.6.0")
        XCTAssertTrue(info.updateAvailable)
        XCTAssertTrue(info.canInstall)
        XCTAssertNil(info.detail)
    }
}
