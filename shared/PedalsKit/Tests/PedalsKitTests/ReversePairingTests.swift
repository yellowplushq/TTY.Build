import XCTest
@testable import PedalsKit

final class ReversePairingTests: XCTestCase {
    func testEnvelopeIsBoundToItsClaimID() throws {
        let hostPrivateKey = PairingKeyAgreement.makePrivateKey()
        let durablePrivateKey = PairingKeyAgreement.makePrivateKey()
        let durablePublicKey = try PairingKeyAgreement.publicKey(for: durablePrivateKey)
        let hostPublicKey = try PairingKeyAgreement.publicKey(for: hostPrivateKey)
        let secret = Data((0 ..< 32).map(UInt8.init))
        let claimID = "fedcba9876543210fedcba9876543210"

        let envelope = try PairingKeyAgreement.seal(
            secret: secret,
            hostPrivateKey: hostPrivateKey,
            clientPublicKey: durablePublicKey,
            claimID: claimID
        )
        XCTAssertEqual(
            try PairingKeyAgreement.open(
                envelope: envelope,
                clientPrivateKey: durablePrivateKey,
                hostPublicKey: hostPublicKey,
                claimID: claimID
            ),
            secret
        )
        XCTAssertThrowsError(
            try PairingKeyAgreement.open(
                envelope: envelope,
                clientPrivateKey: durablePrivateKey,
                hostPublicKey: hostPublicKey,
                claimID: "00000000000000000000000000000000"
            )
        )
    }

    func testTokenUsabilityRespectsExpiryAndMargin() throws {
        let key = PairingKeyAgreement.makePrivateKey()
        let now = Date()
        let live = ReversePairingToken(
            code: try PairingCode("01234567"),
            privateKey: key,
            expiresAt: Int64(now.timeIntervalSince1970) + 3_600
        )
        XCTAssertTrue(live.isUsable(at: now))
        let closing = ReversePairingToken(
            code: try PairingCode("01234567"),
            privateKey: key,
            expiresAt: Int64(now.timeIntervalSince1970) + 30
        )
        XCTAssertFalse(closing.isUsable(at: now))
    }

    func testOpenReversePairingClaimValidatesSecretAndBuildsBinding() throws {
        let serviceURL = URL(string: "https://pedals.air.build")!
        let api = PedalsServiceAPI(serviceURL: serviceURL)
        let token = ReversePairingToken(
            code: try PairingCode("01234567"),
            privateKey: PairingKeyAgreement.makePrivateKey(),
            expiresAt: Int64(Date().timeIntervalSince1970) + 3_600
        )
        let hostPrivateKey = PairingKeyAgreement.makePrivateKey()
        let secret = Data(repeating: 7, count: 32)
        let claimID = "0123456789abcdef0123456789abcdef"
        let computerID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

        let claim = ReversePairingClaim(
            claimID: claimID,
            computerID: computerID,
            computerName: "Studio",
            hostPublicKey: try PairingKeyAgreement.publicKey(for: hostPrivateKey),
            encryptedSecret: try PairingKeyAgreement.seal(
                secret: secret,
                hostPrivateKey: hostPrivateKey,
                clientPublicKey: try PairingKeyAgreement.publicKey(for: token.privateKey),
                claimID: claimID
            ),
            createdAt: 0
        )

        let binding = try api.openReversePairingClaim(claim, token: token)
        XCTAssertEqual(binding.computerID, computerID)
        XCTAssertEqual(binding.secret, secret)
        XCTAssertEqual(binding.serviceURL, serviceURL)

        // A short secret is rejected even when the envelope authenticates.
        let truncated = ReversePairingClaim(
            claimID: claimID,
            computerID: computerID,
            computerName: "Studio",
            hostPublicKey: claim.hostPublicKey,
            encryptedSecret: try PairingKeyAgreement.seal(
                secret: Data(repeating: 7, count: 16),
                hostPrivateKey: hostPrivateKey,
                clientPublicKey: try PairingKeyAgreement.publicKey(for: token.privateKey),
                claimID: claimID
            ),
            createdAt: 0
        )
        XCTAssertThrowsError(try api.openReversePairingClaim(truncated, token: token))
    }
}
