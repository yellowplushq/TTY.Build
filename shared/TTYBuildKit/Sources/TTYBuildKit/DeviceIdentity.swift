import Foundation

/// Long-lived E2EE material for one computer. The Worker stores the identity
/// and binding edge, but never this secret.
///
/// Every instance is validated: the memberwise initializer throws, and
/// `Decodable` routes through it, so persisted or transported data can never
/// materialize a binding that later traps the connection layer.
public struct ComputerBinding: Codable, Equatable, Sendable {
    public static let computerIDLength = 32
    public static let secretByteCount = 32

    public enum ValidationError: Error, Equatable {
        case invalidService(String)
        case invalidComputerID(String)
        case invalidSecretLength(Int)
    }

    public let serviceURL: URL
    public let computerID: String
    public let secret: Data

    public init(serviceURL: URL, computerID: String, secret: Data) throws {
        guard Self.isAllowedService(serviceURL) else {
            throw ValidationError.invalidService(serviceURL.absoluteString)
        }
        let normalizedID = computerID.lowercased()
        guard normalizedID.count == Self.computerIDLength,
              normalizedID.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains($0)) })
        else { throw ValidationError.invalidComputerID(computerID) }
        guard secret.count == Self.secretByteCount else {
            throw ValidationError.invalidSecretLength(secret.count)
        }
        self.serviceURL = serviceURL
        self.computerID = normalizedID
        self.secret = secret
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                serviceURL: container.decode(URL.self, forKey: .serviceURL),
                computerID: container.decode(String.self, forKey: .computerID),
                secret: container.decode(Data.self, forKey: .secret)
            )
        } catch let error as ValidationError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "invalid computer binding: \(error)"
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case serviceURL
        case computerID
        case secret
    }

    public var relayURL: URL {
        guard var components = URLComponents(
            url: serviceURL, resolvingAgainstBaseURL: false
        ) else { return serviceURL }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.query = nil
        components.fragment = nil
        return components.url ?? serviceURL
    }

    static func isAllowedService(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

public struct HostIdentity: Codable, Equatable, Sendable {
    public let computer: ComputerBinding
    public let hostToken: String

    public init(computer: ComputerBinding, hostToken: String) {
        self.computer = computer
        self.hostToken = hostToken
    }
}

/// A relay client principal. Like `ComputerBinding`, instances are validated
/// on construction and on decode: a canonical 32-hex client ID and well-formed
/// bearer tokens are guaranteed everywhere one of these values exists.
public struct ClientIdentity: Codable, Equatable, Sendable {
    public static let clientIDLength = 32

    public enum ValidationError: Error, Equatable {
        case invalidService(String)
        case invalidClientID(String)
        case invalidToken
    }

    public let serviceURL: URL
    public let clientID: String
    public let clientToken: String
    public let statusToken: String

    public init(
        serviceURL: URL,
        clientID: String,
        clientToken: String,
        statusToken: String
    ) throws {
        guard ComputerBinding.isAllowedService(serviceURL) else {
            throw ValidationError.invalidService(serviceURL.absoluteString)
        }
        let normalizedID = clientID.lowercased()
        guard Self.isCanonicalID(normalizedID) else {
            throw ValidationError.invalidClientID(clientID)
        }
        guard Self.isValidToken(clientToken), Self.isValidToken(statusToken) else {
            throw ValidationError.invalidToken
        }
        self.serviceURL = serviceURL
        self.clientID = normalizedID
        self.clientToken = clientToken
        self.statusToken = statusToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                serviceURL: container.decode(URL.self, forKey: .serviceURL),
                clientID: container.decode(String.self, forKey: .clientID),
                clientToken: container.decode(String.self, forKey: .clientToken),
                statusToken: container.decode(String.self, forKey: .statusToken)
            )
        } catch let error as ValidationError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "invalid client identity: \(error)"
            ))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case serviceURL
        case clientID
        case clientToken
        case statusToken
    }

    /// Canonical relay principal: exactly 32 lowercase hexadecimal characters.
    /// Client IDs and computer IDs share this shape.
    public static func isCanonicalID(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == clientIDLength && bytes.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }

    static func isValidToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return (16 ... 512).contains(bytes.count) && bytes.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }
}

enum SecureRandom {
    static func data(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        guard value.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=")
        }) else { return nil }
        let unpadded = value.replacingOccurrences(of: "=", with: "")
        let remainder = unpadded.count % 4
        guard remainder != 1 else { return nil }
        let normalized = unpadded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: remainder == 0 ? 0 : 4 - remainder)
        self.init(base64Encoded: normalized)
    }
}
