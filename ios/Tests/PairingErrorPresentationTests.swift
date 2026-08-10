import TTYBuildKit
import UIKit
import XCTest

@testable import TTYBuild

final class PairingErrorPresentationTests: XCTestCase {
    func testExpiredAndInvalidCodesUseCodeSpecificMessage() {
        for status in [400, 404, 410] {
            XCTAssertEqual(
                PairingErrorPresentation.message(for:
                    TTYBuildServiceAPI.APIError.rejected(
                        status: status,
                        message: "invalid pairing code"
                    )
                ),
                "Code expired or couldn’t be used. Request a new code on your computer."
            )
        }
    }

    func testServiceMismatchIsNotReportedAsExpiredCode() {
        XCTAssertEqual(
            PairingErrorPresentation.message(for: PairingStore.StoreError.serviceMismatch),
            "This installation has pairing data from another TTY.Build service. Restart the app and try again."
        )
    }

    func testNetworkAndRateLimitErrorsHaveDistinctMessages() {
        XCTAssertEqual(
            PairingErrorPresentation.message(for: URLError(.notConnectedToInternet)),
            "Couldn’t reach TTYBuild. Check your connection and try again."
        )
        XCTAssertEqual(
            PairingErrorPresentation.message(for:
                TTYBuildServiceAPI.APIError.rejected(status: 429, message: "slow down")
            ),
            "Too many pairing attempts. Wait a moment and try again."
        )
    }

    @MainActor
    func testPairingWebsiteLinkCanShrinkWithoutTruncatingItsDomain() throws {
        let controller = PairingCodeViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()

        let link = try XCTUnwrap(
            findSubview(
                in: controller.view,
                identifier: "ttybuild.pairing.website"
            ) as? UIButton
        )
        XCTAssertEqual(link.title(for: .normal), "TTY.Build")
        XCTAssertTrue(link.titleLabel?.adjustsFontSizeToFitWidth == true)
        XCTAssertLessThan(link.titleLabel?.minimumScaleFactor ?? 1, 1)
        XCTAssertEqual(link.titleLabel?.lineBreakMode, .byClipping)
        let titleHeight = try XCTUnwrap(link.titleLabel?.bounds.height)
        XCTAssertGreaterThanOrEqual(link.bounds.height - titleHeight, 6)
        XCTAssertFalse(link.titleLabel?.clipsToBounds ?? true)
    }

    @MainActor
    func testPairingDownloadGuideStaysVisibleAboveTallKeyboard() throws {
        let controller = PairingCodeViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()

        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey:
                    CGRect(x: 0, y: 300, width: 320, height: 268),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
                UIResponder.keyboardAnimationCurveUserInfoKey: 7,
            ]
        )
        controller.view.layoutIfNeeded()

        let guide = try XCTUnwrap(
            findSubview(
                in: controller.view,
                identifier: "ttybuild.pairing.download"
            )
        )
        XCTAssertFalse(guide.isHidden)
        XCTAssertEqual(guide.alpha, 1)
        XCTAssertEqual(guide.bounds.height, 208, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(guide.frame.minY, 7.5)
    }

    @MainActor
    func testCopyInstallButtonPutsFullCurlCommandOnPasteboard() throws {
        let controller = PairingCodeViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()

        let copy = try XCTUnwrap(
            findSubview(
                in: controller.view,
                identifier: "ttybuild.pairing.copyInstall"
            ) as? UIButton
        )
        UIPasteboard.general.string = ""
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(
            UIPasteboard.general.string,
            "curl -fsSL https://tty.build/i | bash"
        )
    }

    @MainActor
    private func findSubview(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let match = findSubview(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}
