import Foundation
import PedalsKit
import XCTest

@testable import PedalsDaemonCore

final class EnrollmentCodeStampTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        bundleURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stamp-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    private func stamp(_ value: String) {
        value.withCString { pointer in
            _ = setxattr(
                bundleURL.path,
                EnrollmentCodeStamp.attributeName,
                pointer,
                strlen(pointer),
                0,
                0
            )
        }
    }

    func testReadsValidatesAndClearsTheStampedCode() throws {
        XCTAssertNil(EnrollmentCodeStamp.read(bundleURL: bundleURL))

        stamp("90285513")
        XCTAssertEqual(
            EnrollmentCodeStamp.read(bundleURL: bundleURL),
            try PairingCode("90285513")
        )

        EnrollmentCodeStamp.clear(bundleURL: bundleURL)
        XCTAssertNil(EnrollmentCodeStamp.read(bundleURL: bundleURL))
        // Clearing an absent stamp is a no-op.
        EnrollmentCodeStamp.clear(bundleURL: bundleURL)
    }

    func testRejectsMalformedStamps() {
        for value in ["1234567", "1234ABCD", "", String(repeating: "9", count: 80)] {
            EnrollmentCodeStamp.clear(bundleURL: bundleURL)
            stamp(value)
            XCTAssertNil(
                EnrollmentCodeStamp.read(bundleURL: bundleURL),
                "accepted \(value)"
            )
        }
    }
}
