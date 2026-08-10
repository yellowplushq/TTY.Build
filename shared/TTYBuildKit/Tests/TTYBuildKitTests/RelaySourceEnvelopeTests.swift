import XCTest
@testable import TTYBuildKit

final class RelaySourceEnvelopeTests: XCTestCase {
    private let clientA = "0123456789abcdef0123456789abcdef"
    private let clientB = "fedcba9876543210fedcba9876543210"
    private let computerID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func encodedEnvelope(
        version: UInt8 = RelaySourceEnvelope.version,
        principal: String,
        wire: Data
    ) -> Data {
        var data = Data([version])
        data.append(contentsOf: principal.utf8)
        data.append(wire)
        return data
    }

    func testDecodesCanonicalVersionTwoEnvelopeWithoutChangingWire() throws {
        let wire = Data((0..<96).map(UInt8.init))
        let value = try XCTUnwrap(RelaySourceEnvelope(
            data: encodedEnvelope(principal: clientA, wire: wire)
        ))
        XCTAssertEqual(value.principal, clientA)
        XCTAssertEqual(value.wire, wire)
        XCTAssertEqual(RelaySourceEnvelope.headerByteCount, 33)
    }

    func testRejectsMissingWrongVersionAndNonCanonicalPrincipal() {
        let wire = Data(repeating: 0x44, count: 64)
        XCTAssertNil(RelaySourceEnvelope(data: wire))
        XCTAssertNil(RelaySourceEnvelope(data: encodedEnvelope(
            version: 0x01, principal: clientA, wire: wire
        )))
        XCTAssertNil(RelaySourceEnvelope(data: encodedEnvelope(
            principal: clientA.uppercased(), wire: wire
        )))
        XCTAssertNil(RelaySourceEnvelope(data: encodedEnvelope(
            principal: String(repeating: "g", count: 32), wire: wire
        )))
        XCTAssertNil(RelaySourceEnvelope(data: Data([RelaySourceEnvelope.version])
            + Data(clientA.utf8)))
    }

    func testHostHelloMustMatchAuthenticatedEnvelopePrincipalExactly() {
        XCTAssertEqual(
            RelaySourceEnvelope.authenticatedHelloPrincipal(
                localRole: .host,
                envelopeSource: clientA,
                claimedPrincipal: clientA,
                computerID: computerID
            ),
            clientA
        )
        XCTAssertNil(RelaySourceEnvelope.authenticatedHelloPrincipal(
            localRole: .host,
            envelopeSource: clientA,
            claimedPrincipal: clientB,
            computerID: computerID
        ))
        XCTAssertNil(RelaySourceEnvelope.authenticatedHelloPrincipal(
            localRole: .host,
            envelopeSource: nil,
            claimedPrincipal: clientA,
            computerID: computerID
        ))
    }

    func testClientStillRequiresUnenvelopedCanonicalComputerHello() {
        XCTAssertEqual(
            RelaySourceEnvelope.authenticatedHelloPrincipal(
                localRole: .client,
                envelopeSource: nil,
                claimedPrincipal: computerID,
                computerID: computerID
            ),
            computerID
        )
        XCTAssertNil(RelaySourceEnvelope.authenticatedHelloPrincipal(
            localRole: .client,
            envelopeSource: clientA,
            claimedPrincipal: computerID,
            computerID: computerID
        ))
        XCTAssertNil(RelaySourceEnvelope.authenticatedHelloPrincipal(
            localRole: .client,
            envelopeSource: nil,
            claimedPrincipal: computerID.uppercased(),
            computerID: computerID
        ))
    }

    func testPendingAndActiveFramesAreBoundToTheirAuthenticatedSource() {
        XCTAssertTrue(RelaySourceEnvelope.authorizesPeerFrame(
            localRole: .host,
            envelopeSource: clientA,
            boundPrincipal: clientA
        ))
        XCTAssertFalse(RelaySourceEnvelope.authorizesPeerFrame(
            localRole: .host,
            envelopeSource: clientA,
            boundPrincipal: clientB
        ))
        XCTAssertFalse(RelaySourceEnvelope.authorizesPeerFrame(
            localRole: .host,
            envelopeSource: nil,
            boundPrincipal: clientA
        ))
        XCTAssertTrue(RelaySourceEnvelope.authorizesPeerFrame(
            localRole: .client,
            envelopeSource: nil,
            boundPrincipal: computerID
        ))
        XCTAssertFalse(RelaySourceEnvelope.authorizesPeerFrame(
            localRole: .client,
            envelopeSource: clientA,
            boundPrincipal: computerID
        ))
    }
}
