import CryptoKit
import XCTest
@testable import TTYBuildKit

final class KeyDerivationTests: XCTestCase {
    private let secret = Data(repeating: 0x42, count: 32)

    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    func testConnectionNoncesDeriveDistinctKeysAndRoutingTags() {
        let first = KeyDerivation.ConnectionBinding(
            hostNonce: Data(repeating: 0x10, count: 32),
            clientNonce: Data(repeating: 0x20, count: 32)
        )
        let second = KeyDerivation.ConnectionBinding(
            hostNonce: Data(repeating: 0x10, count: 32),
            clientNonce: Data(repeating: 0x21, count: 32)
        )

        XCTAssertEqual(first.tag.count, 16)
        XCTAssertEqual(second.tag.count, 16)
        XCTAssertNotEqual(first.tag, second.tag)
        XCTAssertNotEqual(
            bytes(KeyDerivation.hostToClientKey(secret: secret, connection: first)),
            bytes(KeyDerivation.hostToClientKey(secret: secret, connection: second))
        )
        XCTAssertNotEqual(
            bytes(KeyDerivation.clientToHostKey(secret: secret, connection: first)),
            bytes(KeyDerivation.clientToHostKey(secret: secret, connection: second))
        )
    }

    func testSameConnectionBindingIsDeterministicAndDirectionsStaySeparated() {
        let binding = KeyDerivation.ConnectionBinding(
            hostNonce: Data((0..<32).map(UInt8.init)),
            clientNonce: Data((32..<64).map(UInt8.init))
        )
        let firstHostToClient = bytes(
            KeyDerivation.hostToClientKey(secret: secret, connection: binding)
        )
        let secondHostToClient = bytes(
            KeyDerivation.hostToClientKey(secret: secret, connection: binding)
        )
        let clientToHost = bytes(
            KeyDerivation.clientToHostKey(secret: secret, connection: binding)
        )

        XCTAssertEqual(firstHostToClient, secondHostToClient)
        XCTAssertNotEqual(firstHostToClient, clientToHost)
    }
}
