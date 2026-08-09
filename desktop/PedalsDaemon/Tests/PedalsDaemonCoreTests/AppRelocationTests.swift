import Foundation
import XCTest

@testable import PedalsDaemonCore

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
        let result = try XCTUnwrap(plan("/Users/sample/Downloads/Pedals.app"))
        XCTAssertEqual(result.destinationURL.path, "/Applications/Pedals.app")
        XCTAssertTrue(result.deleteSource)
    }

    func testFallsBackToUserApplicationsWhenSystemIsNotWritable() throws {
        let result = try XCTUnwrap(
            plan("/Users/sample/Downloads/Pedals.app", systemWritable: false)
        )
        XCTAssertEqual(result.destinationURL.path, "/Users/sample/Applications/Pedals.app")
    }

    func testKeepsTheOriginalWhenTheSourceVolumeIsReadOnly() throws {
        let result = try XCTUnwrap(
            plan("/Volumes/Pedals/Pedals.app", readOnlyVolume: true)
        )
        XCTAssertEqual(result.destinationURL.path, "/Applications/Pedals.app")
        XCTAssertFalse(result.deleteSource)
    }

    func testSkipsBundlesAlreadyInsideAnyApplicationsFolder() {
        XCTAssertNil(plan("/Applications/Pedals.app"))
        XCTAssertNil(plan("/Users/sample/Applications/Pedals.app"))
        XCTAssertNil(plan("/Applications/Utilities/Pedals.app"))
        XCTAssertNil(plan("/Users/sample/Applications/Tools/Pedals.app"))
    }

    func testSkipsDevelopmentBuildsAndNonBundles() {
        XCTAssertNil(plan(
            "/Users/sample/Library/Developer/Xcode/DerivedData/P-abc/Build/Products/Debug/Pedals.app"
        ))
        XCTAssertNil(plan("/Users/sample/repo/.artifacts/Build/Products/Release/Pedals.app"))
        XCTAssertNil(plan("/Users/sample/output.xcarchive/Products/Applications/Pedals.app"))
        XCTAssertNil(plan("/Users/sample/Downloads/Pedals"))
    }
}
