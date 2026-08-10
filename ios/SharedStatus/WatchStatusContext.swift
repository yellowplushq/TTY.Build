import Foundation

public struct WatchStatusContext: Codable, Sendable {
    public static let applicationContextKey = "ttybuild.status.context.v4"

    public let credential: TTYBuildStatusCredential
    public let snapshot: TTYStatusSnapshot

    public init(credential: TTYBuildStatusCredential, snapshot: TTYStatusSnapshot) {
        self.credential = credential
        self.snapshot = snapshot
    }

    public var applicationContext: [String: Any] {
        guard let data = try? JSONEncoder.ttybuild.encode(self) else { return [:] }
        return [Self.applicationContextKey: data]
    }

    public init?(applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.applicationContextKey] as? Data,
              let decoded = try? JSONDecoder.ttybuild.decode(Self.self, from: data)
        else { return nil }
        self = decoded
    }
}
