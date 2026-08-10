import Foundation
import TTYBuildKit

/// The Watch's independent relay credential plus E2EE bindings copied from the
/// paired iPhone. The Worker never sees this payload; WatchConnectivity moves
/// it between the two app installations and the Watch stores it in Keychain.
///
/// v2 payload rules (no compatibility with v1):
/// - Every field is validated on decode (`ClientIdentity`/`ComputerBinding`
///   route decoding through their throwing initializers), so a stale or
///   corrupt payload can never install a credential that traps at connect.
/// - `revision` is a phone-stamped monotonic value. The Watch ignores any
///   update older than what it already installed, so an out-of-order
///   WatchConnectivity delivery cannot regress or wipe a fresh credential.
public struct WatchTerminalContext: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let applicationContextKey = "ttybuild.terminal.context.v2"
    public static let applicationContextPresenceKey = "ttybuild.terminal.context.present.v2"
    public static let applicationContextRevisionKey = "ttybuild.terminal.context.revision.v2"
    public static let requestMessageKey = "ttybuild.terminal.context.request.v2"

    public let schema: Int
    public let revision: UInt64
    public let identity: ClientIdentity
    public let bindings: [ComputerBinding]

    public init(identity: ClientIdentity, bindings: [ComputerBinding], revision: UInt64) {
        self.schema = Self.schemaVersion
        self.revision = revision
        self.identity = identity
        self.bindings = bindings.filter { $0.serviceURL == identity.serviceURL }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "unsupported watch terminal context schema \(schema)"
            ))
        }
        self.init(
            identity: try container.decode(ClientIdentity.self, forKey: .identity),
            bindings: try container.decode([ComputerBinding].self, forKey: .bindings),
            revision: try container.decode(UInt64.self, forKey: .revision)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case revision
        case identity
        case bindings
    }

    /// Milliseconds since the Unix epoch: monotonic enough across phone
    /// reinstalls to order context updates.
    public static var currentRevision: UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970) * 1000)
    }
}

/// One versioned watch-credential update: either a full context or an
/// authoritative "no credential" state, both carrying the phone's revision.
public struct WatchTerminalContextUpdate: Equatable, Sendable {
    public let revision: UInt64
    public let context: WatchTerminalContext?

    public init(context: WatchTerminalContext) {
        self.revision = context.revision
        self.context = context
    }

    public init(clearedAtRevision revision: UInt64) {
        self.revision = revision
        self.context = nil
    }

    public var applicationContext: [String: Any] {
        var value: [String: Any] = [
            WatchTerminalContext.applicationContextPresenceKey: true,
            WatchTerminalContext.applicationContextRevisionKey: NSNumber(value: revision),
        ]
        if let context, let data = try? JSONEncoder().encode(context) {
            value[WatchTerminalContext.applicationContextKey] = data
        }
        return value
    }

    /// Returns nil when the dictionary carries no v2 terminal payload or a
    /// payload that fails validation. An undecodable payload is deliberately
    /// NOT a "clear credentials" signal: only an explicit, well-formed empty
    /// update may remove a working credential from the Watch.
    public init?(applicationContext: [String: Any]) {
        guard applicationContext[
            WatchTerminalContext.applicationContextPresenceKey
        ] as? Bool == true,
            let revision = (applicationContext[
                WatchTerminalContext.applicationContextRevisionKey
            ] as? NSNumber)?.uint64Value
        else { return nil }

        if let data = applicationContext[
            WatchTerminalContext.applicationContextKey
        ] as? Data {
            guard let context = try? JSONDecoder().decode(
                WatchTerminalContext.self, from: data
            ) else { return nil }
            self.init(context: context)
        } else {
            self.init(clearedAtRevision: revision)
        }
    }
}
