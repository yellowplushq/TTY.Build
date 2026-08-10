import XCTest
@testable import TTYBuild

@MainActor
final class AEOTPTextFieldTests: XCTestCase {
    func testInputAcceptsEightASCIIDigitsAndRejectsOverflow() {
        let field = AEOTPTextField()
        field.configure(with: 8)

        XCTAssertEqual(
            field.delegate?.textField?(
                field,
                shouldChangeCharactersIn: NSRange(location: 0, length: 0),
                replacementString: "01234567"
            ),
            true
        )

        field.text = "01234567"
        XCTAssertEqual(
            field.delegate?.textField?(
                field,
                shouldChangeCharactersIn: NSRange(location: 8, length: 0),
                replacementString: "8"
            ),
            false
        )
    }

    func testInputRejectsNonASCIIDigits() {
        let field = AEOTPTextField()
        field.configure(with: 8)

        for invalid in ["a", " ", "١"] {
            XCTAssertEqual(
                field.delegate?.textField?(
                    field,
                    shouldChangeCharactersIn: NSRange(location: 0, length: 0),
                    replacementString: invalid
                ),
                false
            )
        }
    }
}
