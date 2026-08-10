import Foundation
import XCTest

@testable import TTYBuildDaemonCore

final class AppRelocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/sample", isDirectory: true)

    private func plan(
        _ path: String,
        systemWritable: Bool = true,
        readOnlyVolume: Bool = false
    ) -> AppRelocation.Plan? {
        AppRelocation.plan(
            bundleURL: URL(fileURLWithPath: path, isDirectory: true),
            systemApplicationsWritable: systemWritable,
            sourceVolumeReadOnly: readOnlyVolume,
            homeDirectory: home
        )
    }

    func testMovesFromDownloadsIntoSystemApplications() throws {
        let result = try XCTUnwrap(plan("/Users/sample/Downloads/TTYBuild.app"))
        XCTAssertEqual(result.destinationURL.path, "/Applications/TTYBuild.app")
        XCTAssertTrue(result.deleteSource)
    }

    func testFallsBackToUserApplicationsWhenSystemIsNotWritable() throws {
        let result = try XCTUnwrap(
            plan("/Users/sample/Downloads/TTYBuild.app", systemWritable: false)
        )
        XCTAssertEqual(result.destinationURL.path, "/Users/sample/Applications/TTYBuild.app")
    }

    func testKeepsTheOriginalWhenTheSourceVolumeIsReadOnly() throws {
        let result = try XCTUnwrap(
            plan("/Volumes/tty.build/TTYBuild.app", readOnlyVolume: true)
        )
        XCTAssertEqual(result.destinationURL.path, "/Applications/TTYBuild.app")
        XCTAssertFalse(result.deleteSource)
    }

    func testSkipsBundlesAlreadyInsideAnyApplicationsFolder() {
        XCTAssertNil(plan("/Applications/TTYBuild.app"))
        XCTAssertNil(plan("/Users/sample/Applications/TTYBuild.app"))
        XCTAssertNil(plan("/Applications/Utilities/TTYBuild.app"))
        XCTAssertNil(plan("/Users/sample/Applications/Tools/TTYBuild.app"))
    }

    func testSkipsDevelopmentBuildsAndNonBundles() {
        XCTAssertNil(plan(
            "/Users/sample/Library/Developer/Xcode/DerivedData/P-abc/Build/Products/Debug/TTYBuild.app"
        ))
        XCTAssertNil(plan("/Users/sample/repo/.artifacts/Build/Products/Release/TTYBuild.app"))
        XCTAssertNil(plan("/Users/sample/output.xcarchive/Products/Applications/TTYBuild.app"))
        XCTAssertNil(plan("/Users/sample/Downloads/tty.build"))
    }
}
