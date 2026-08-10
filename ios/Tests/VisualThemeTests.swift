import UIKit
import XCTest

@testable import TTYBuild

@MainActor
final class VisualThemeTests: XCTestCase {
    func testMonochromeUIKitPaletteUsesOnlyWhiteWithAlphaOnBlack() {
        assertWhite(TTYBuildTheme.uiCanvas, component: 0, alpha: 1)
        assertWhite(TTYBuildTheme.uiContent, component: 1, alpha: 1)
        assertWhite(TTYBuildTheme.uiSecondaryContent, component: 1, alpha: 0.64)
        assertWhite(TTYBuildTheme.uiTertiaryContent, component: 1, alpha: 0.38)
        assertWhite(TTYBuildTheme.uiSurface, component: 1, alpha: 0.08)
        assertWhite(TTYBuildTheme.uiSeparator, component: 1, alpha: 0.16)
        assertWhite(TTYBuildTheme.uiSelection, component: 1, alpha: 0.18)
    }

    func testColoredRolesAreLimitedToWarningAndCritical() {
        XCTAssertEqual(TTYBuildTheme.uiWarning, UIColor.systemOrange)
        XCTAssertEqual(TTYBuildTheme.uiCritical, UIColor.systemRed)
    }

    func testBrandMarkIsPackagedForOnboarding() {
        XCTAssertNotNil(UIImage(named: "AppMark"))
    }

    private func assertWhite(
        _ color: UIColor,
        component expectedComponent: CGFloat,
        alpha expectedAlpha: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var component: CGFloat = -1
        var alpha: CGFloat = -1
        XCTAssertTrue(
            color.getWhite(&component, alpha: &alpha),
            "Expected a monochrome color",
            file: file,
            line: line
        )
        XCTAssertEqual(component, expectedComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.001, file: file, line: line)
    }
}
