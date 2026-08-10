import Foundation
import XCTest

@testable import TTYBuildKit

final class DeviceIdentityValidationTests: XCTestCase {
    private let service = URL(string: "https://relay.test")!

    private func canonicalID(_ marker: Character) -> String {
        String(repeating: marker, count: ClientIdentity.clientIDLength)
    }

    private func makeIdentity(
        clientID: String? = nil,
        clientToken: String = "token-0123456789abcdef",
        statusToken: String = "status-0123456789abcdef"
    ) throws -> ClientIdentity {
        try ClientIdentity(
            serviceURL: service,
            clientID: clientID ?? canonicalID("a"),
            clientToken: clientToken,
            statusToken: statusToken
        )
    }

    func testClientIdentityRoundTripsThroughCodable() throws {
        let identity = try makeIdentity()
        let decoded = try JSONDecoder().decode(
            ClientIdentity.self,
            from: JSONEncoder().encode(identity)
        )
        XCTAssertEqual(decoded, identity)
    }

    func testClientIdentityUppercaseIDIsNormalized() throws {
        let identity = try makeIdentity(clientID: canonicalID("A"))
        XCTAssertEqual(identity.clientID, canonicalID("a"))
    }

    func testClientIdentityRejectsNonCanonicalIDs() {
        for bad in [
            "", "abc",
            String(repeating: "a", count: 31),
            String(repeating: "a", count: 33),
            String(repeating: "g", count: 32),
            String(repeating: "a", count: 30) + "-!",
        ] {
            XCTAssertThrowsError(try makeIdentity(clientID: bad), bad)
        }
    }

    func testClientIdentityRejectsMalformedTokens() {
        XCTAssertThrowsError(try makeIdentity(clientToken: ""))
        XCTAssertThrowsError(try makeIdentity(clientToken: "short"))
        XCTAssertThrowsError(try makeIdentity(clientToken: "has spaces in this token"))
        XCTAssertThrowsError(try makeIdentity(statusToken: "bad token bad token"))
    }

    func testClientIdentityRejectsDisallowedService() {
        XCTAssertThrowsError(try ClientIdentity(
            serviceURL: URL(string: "http://relay.test")!,
            clientID: canonicalID("a"),
            clientToken: "token-0123456789abcdef",
            statusToken: "status-0123456789abcdef"
        ))
    }

    /// The launch-crash class this guards against: a persisted credential that
    /// no longer matches the current format must fail decoding instead of
    /// materializing a value that traps deeper in the connection stack.
    func testDecodingRejectsNonCanonicalPersistedClientIdentity() throws {
        let json = """
        {
          "serviceURL": "https://relay.test",
          "clientID": "watch-legacy-client-identifier",
          "clientToken": "token-0123456789abcdef",
          "statusToken": "status-0123456789abcdef"
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ClientIdentity.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testDecodingRejectsComputerBindingWithWrongSecretLength() throws {
        let shortSecret = Data(repeating: 1, count: 16).base64EncodedString()
        let json = """
        {
          "serviceURL": "https://relay.test",
          "computerID": "\(canonicalID("b"))",
          "secret": "\(shortSecret)"
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComputerBinding.self, from: Data(json.utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testComputerBindingRoundTripsThroughCodable() throws {
        let binding = try ComputerBinding(
            serviceURL: service,
            computerID: canonicalID("b"),
            secret: Data(repeating: 7, count: ComputerBinding.secretByteCount)
        )
        let decoded = try JSONDecoder().decode(
            ComputerBinding.self,
            from: JSONEncoder().encode(binding)
        )
        XCTAssertEqual(decoded, binding)
    }

    func testRelayURLNeverTraps() throws {
        let binding = try ComputerBinding(
            serviceURL: URL(string: "http://localhost:8787/base")!,
            computerID: canonicalID("c"),
            secret: Data(repeating: 7, count: ComputerBinding.secretByteCount)
        )
        XCTAssertEqual(binding.relayURL.scheme, "ws")
    }
}
