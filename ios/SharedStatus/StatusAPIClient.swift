import Foundation

public enum PushSurface: String, Codable, CaseIterable, Sendable {
    /// Visible alerts to the app itself (reverse-pairing claims).
    case iOSApp = "ios-app"
    case iOSWidget = "ios-widget"
    case watchWidget = "watch-widget"
    case iOSLiveActivityStart = "liveactivity-start"
    case iOSLiveActivityUpdate = "liveactivity-update"
}

public enum APNSEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    public static var current: Self {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

public struct PushEndpointRegistration: Codable, Hashable, Sendable {
    public let surface: PushSurface
    public let token: String
    public let environment: APNSEnvironment
    public let activityId: String?

    public init(
        surface: PushSurface,
        token: String,
        environment: APNSEnvironment = .current,
        activityId: String? = nil
    ) {
        self.surface = surface
        self.token = token
        self.environment = environment
        self.activityId = activityId
    }

}

public struct PendingPushEndpointMutation: Codable, Hashable, Sendable {
    public enum Operation: String, Codable, Sendable { case put, delete }

    public let operation: Operation
    public let surface: PushSurface
    public let registration: PushEndpointRegistration?
    public let activityId: String?

    public static func put(_ registration: PushEndpointRegistration) -> Self {
        .init(
            operation: .put,
            surface: registration.surface,
            registration: registration,
            activityId: registration.activityId
        )
    }

    public static func delete(_ surface: PushSurface, activityId: String? = nil) -> Self {
        .init(
            operation: .delete,
            surface: surface,
            registration: nil,
            activityId: activityId
        )
    }

    var identity: String {
        "\(surface.rawValue):\(activityId ?? "default")"
    }
}

private struct PushEndpointRequestBody: Encodable {
    let token: String
    let environment: APNSEnvironment
    let activityId: String?
}

public enum StatusAPIError: Error, LocalizedError, Sendable {
    case invalidResponse
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The status service returned an invalid response."
        case .http(let status, let body):
            "The status service returned HTTP \(status): \(body)"
        }
    }
}

public struct StatusAPIClient: Sendable {
    public init() {}

    public func fetchState(credential: TTYBuildStatusCredential) async throws -> TTYStatusSnapshot {
        var request = URLRequest(
            url: Self.endpoint("v2/clients/me/state", baseURL: credential.serviceURL)
        )
        request.httpMethod = "GET"
        authorize(&request, credential: credential)
        let data = try await perform(request)
        return try JSONDecoder.ttybuild.decode(TTYStatusSnapshot.self, from: data)
    }

    public func putPushEndpoint(
        _ registration: PushEndpointRegistration,
        credential: TTYBuildStatusCredential
    ) async throws {
        var request = URLRequest(
            url: Self.pushEndpointURL(
                registration.surface,
                baseURL: credential.serviceURL
            )
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PushEndpointRequestBody(
                token: registration.token,
                environment: registration.environment,
                activityId: registration.activityId
            )
        )
        authorize(&request, credential: credential)
        _ = try await perform(request)
    }

    public func deletePushEndpoint(
        _ surface: PushSurface,
        activityId: String? = nil,
        credential: TTYBuildStatusCredential
    ) async throws {
        var request = URLRequest(
            url: Self.pushEndpointURL(
                surface,
                activityId: activityId,
                baseURL: credential.serviceURL
            )
        )
        request.httpMethod = "DELETE"
        authorize(&request, credential: credential)
        _ = try await perform(request)
    }

    static func pushEndpointURL(
        _ surface: PushSurface,
        activityId: String? = nil,
        baseURL: URL
    ) -> URL {
        let url = endpoint(
            "v2/clients/me/push-endpoints/\(surface.rawValue)",
            baseURL: baseURL
        )
        guard let activityId else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "activityId", value: activityId)]
        return components?.url ?? url
    }

    private static func endpoint(_ path: String, baseURL: URL) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private func authorize(_ request: inout URLRequest, credential: TTYBuildStatusCredential) {
        request.setValue("Bearer \(credential.statusToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.clientID, forHTTPHeaderField: "X-TTYBuild-Client-ID")
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw StatusAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw StatusAPIError.http(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }
}

public enum TTYBuildStatusRuntime {
    public static func installCredential(_ credential: TTYBuildStatusCredential) async {
        await StatusSharedStore.saveCredential(credential)
        await PushEndpointRegistrar.flushPending()
    }

    @discardableResult
    public static func refreshState() async throws -> TTYStatusSnapshot {
        guard let credential = StatusSharedStore.credential() else {
            return StatusSharedStore.snapshot()
        }
        let snapshot = try await StatusAPIClient().fetchState(credential: credential)
        return StatusSharedStore.saveSnapshot(snapshot)
    }
}

private actor PushEndpointRetryScheduler {
    static let shared = PushEndpointRetryScheduler()

    private var scheduledAt: Date?
    private var sleeper: Task<Void, Never>?

    func schedule(at requestedDate: Date?) {
        guard let requestedDate else {
            scheduledAt = nil
            sleeper?.cancel()
            sleeper = nil
            return
        }
        if let scheduledAt, scheduledAt <= requestedDate { return }

        scheduledAt = requestedDate
        sleeper?.cancel()
        sleeper = Task { [requestedDate] in
            let delay = max(0, requestedDate.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, scheduledAt == requestedDate else { return }
            scheduledAt = nil
            sleeper = nil
            // The worker isn't retained as the sleeper. A new foreground/token
            // trigger can schedule another probe without cancelling network I/O
            // that has already claimed a durable mutation.
            Task {
                await PushEndpointRegistrar.flushPending()
            }
        }
    }
}

public enum PushEndpointRegistrar {
    /// Best-effort immediate trigger for synchronous system callbacks. The
    /// mutation is already durable, so suspension or process death is recovered
    /// by the claim lease and a later foreground/timeline trigger.
    public static func requestFlush() {
        Task {
            await PushEndpointRetryScheduler.shared.schedule(at: .now)
        }
    }

    public static func registerOrQueue(_ registration: PushEndpointRegistration) async {
        let mutation = PendingPushEndpointMutation.put(registration)
        StatusSharedStore.savePendingPushMutation(mutation)
        await flushPending()
    }

    public static func unregisterOrQueue(
        _ surface: PushSurface,
        activityId: String? = nil
    ) async {
        let mutation = PendingPushEndpointMutation.delete(
            surface,
            activityId: activityId
        )
        StatusSharedStore.savePendingPushMutation(mutation)
        await flushPending()
    }

    public static func flushPending() async {
        let client = StatusAPIClient()
        while !Task.isCancelled {
            let decision = StatusSharedStore.claimNextPushMutation()
            guard let delivery = decision.delivery else {
                await PushEndpointRetryScheduler.shared.schedule(
                    at: decision.nextAttemptAt
                )
                return
            }

            do {
                switch delivery.claim.mutation.operation {
                case .put:
                    guard let registration = delivery.claim.mutation.registration else {
                        StatusSharedStore.completePushMutation(delivery.claim)
                        continue
                    }
                    try await client.putPushEndpoint(
                        registration, credential: delivery.credential
                    )
                case .delete:
                    try await client.deletePushEndpoint(
                        delivery.claim.mutation.surface,
                        activityId: delivery.claim.mutation.activityId,
                        credential: delivery.credential
                    )
                }
            } catch {
                let retryAt = StatusSharedStore.failPushMutation(delivery.claim)
                await PushEndpointRetryScheduler.shared.schedule(at: retryAt)
                return
            }
            StatusSharedStore.completePushMutation(delivery.claim)
        }

    }
}
