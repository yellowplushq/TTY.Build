import XCTest
@testable import PedalsKit

final class PairingCodeTests: XCTestCase {
    func testAcceptsEightDigitsAndFormatsFourByFour() throws {
        XCTAssertEqual(try PairingCode("01234567").digits, "01234567")
        XCTAssertEqual(try PairingCode("0123 4567").formatted, "0123 4567")
        XCTAssertEqual(try PairingCode("0123-4567").digits, "01234567")
    }

    func testRejectsWrongLengthAndNonDigits() {
        for value in ["1234567", "123456789", "1234ABCD", "１２３４５６７８"] {
            XCTAssertThrowsError(try PairingCode(value), "accepted \(value)")
        }
    }

    func testEphemeralAgreementTransfersSecretWithoutUsingCodeAsKey() throws {
        let hostPrivateKey = PairingKeyAgreement.makePrivateKey()
        let clientPrivateKey = PairingKeyAgreement.makePrivateKey()
        let clientPublicKey = try PairingKeyAgreement.publicKey(for: clientPrivateKey)
        let hostPublicKey = try PairingKeyAgreement.publicKey(for: hostPrivateKey)
        let secret = Data((0 ..< 32).map(UInt8.init))
        let claimID = "0123456789abcdef0123456789abcdef"

        let envelope = try PairingKeyAgreement.seal(
            secret: secret,
            hostPrivateKey: hostPrivateKey,
            clientPublicKey: clientPublicKey,
            claimID: claimID
        )
        XCTAssertNotEqual(envelope, secret)
        XCTAssertEqual(
            try PairingKeyAgreement.open(
                envelope: envelope,
                clientPrivateKey: clientPrivateKey,
                hostPublicKey: hostPublicKey,
                claimID: claimID
            ),
            secret
        )
        XCTAssertThrowsError(
            try PairingKeyAgreement.open(
                envelope: envelope,
                clientPrivateKey: clientPrivateKey,
                hostPublicKey: hostPublicKey,
                claimID: String(repeating: "f", count: 32)
            )
        )
    }
}
