import Foundation

/// HTTP long-poll replacement for the relay WebSocket, for platforms where a
/// WebSocket cannot be established at all. watchOS routes plain HTTP requests
/// through the paired iPhone's Bluetooth companion proxy, but WebSockets
/// require a direct Wi-Fi/cellular path and otherwise fail immediately with
/// NSURLErrorNotConnectedToInternet.
///
/// One instance models one logical connection attempt, mirroring a socket:
/// `start` opens a server-side poll session, `onClosed` is terminal, and the
/// owner reconnects with a fresh instance. Downlink is a parked GET the relay
/// answers within ~20 s (messages or an empty batch); the client acknowledges
/// delivered messages via the `after` cursor, so a response lost in transit is
/// redelivered. Uplink is a serialized POST of big-endian length-prefixed
/// E2EE wires, preserving send order.
///
/// All public methods must be called on `queue`; callbacks are dispatched on
/// the same queue.
final class RelayHTTPTransport: @unchecked Sendable {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClosed: ((_ unauthorized: Bool) -> Void)?

    /// `.../v2/relay/<computerID>/http?channel=...` without poll parameters.
    private let endpoint: URL
    private let authorization: String
    private let queue: DispatchQueue
    private let urlSession: URLSession
    private let sessionToken: String
    private var after: UInt64?
    private var opened = false
    private var closed = false
    private var suspended = false
    /// The one in-flight downlink poll, kept for cancellation by `pause()`.
    private var pollTask: URLSessionDataTask?
    /// Bumped for every issued poll and on `pause()`. Completions compare
    /// against it so a cancelled or superseded poll can never close the
    /// transport or double-deliver.
    private var pollGeneration = 0
    private var pendingWires: [Data] = []
    private var sendInFlight = false

    /// The relay parks a poll for up to 20 s; leave margin for slow proxies.
    private static let pollTimeout: TimeInterval = 40
    private static let sendTimeout: TimeInterval = 15
    /// Mirrors the relay's per-POST limits.
    private static let maximumWiresPerBatch = 64
    private static let maximumBatchBytes = 512 * 1024

    init(endpoint: URL, authorization: String, queue: DispatchQueue) {
        self.endpoint = endpoint
        self.authorization = authorization
        self.queue = queue
        sessionToken = SecureRandom.data(count: 16)
            .map { String(format: "%02x", $0) }
            .joined()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = Self.pollTimeout
        urlSession = URLSession(configuration: configuration)
    }

    func start() {
        pollNext()
    }

    func stop() {
        closed = true
        pollTask = nil
        urlSession.invalidateAndCancel()
    }

    /// Parks the transport across a platform suspension (watch wrist-down):
    /// cancels the in-flight poll but keeps the server session token and the
    /// `after` cursor. Un-acked messages are redelivered on `resume()`, so a
    /// response lost to the cancellation is safe. Queued uplink wires are held
    /// until `resume()`.
    func pause() {
        guard !closed, !suspended else { return }
        suspended = true
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// Continues a paused transport with the same poll session and cursor.
    /// If the relay expired the session meanwhile, the next poll answers
    /// `reset: true` and the transport closes — the owner reconnects fresh.
    func resume() {
        guard !closed, suspended else { return }
        suspended = false
        pollNext()
        drainSendsLocked()
    }

    func send(_ wire: Data) {
        guard !closed else { return }
        pendingWires.append(wire)
        drainSendsLocked()
    }

    // MARK: - Downlink (on `queue`)

    private func pollNext() {
        guard !closed, !suspended,
              var components = URLComponents(
                  url: endpoint, resolvingAgainstBaseURL: false
              )
        else { return }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "session", value: sessionToken))
        if let after {
            query.append(URLQueryItem(name: "after", value: String(after)))
        }
        components.queryItems = query
        guard let url = components.url else {
            closeLocked(unauthorized: false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.pollTimeout
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        pollGeneration += 1
        let generation = pollGeneration
        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.pollGeneration else { return }
                self.pollTask = nil
                self.handlePoll(data: data, response: response, error: error)
            }
        }
        pollTask = task
        task.resume()
    }

    private struct PollResponse: Decodable {
        struct Message: Decodable {
            var t: String?
            var b: String?
        }

        var next: UInt64?
        var reset: Bool?
        var messages: [Message]?
    }

    private func handlePoll(data: Data?, response: URLResponse?, error: Error?) {
        guard !closed else { return }
        guard error == nil, let status = (response as? HTTPURLResponse)?.statusCode else {
            closeLocked(unauthorized: false)
            return
        }
        guard status == 200 else {
            closeLocked(unauthorized: status == 401 || status == 403)
            return
        }
        guard let data,
              let batch = try? JSONDecoder().decode(PollResponse.self, from: data)
        else {
            closeLocked(unauthorized: false)
            return
        }
        if batch.reset == true {
            // The relay lost the poll session (eviction, expiry, replacement);
            // only a fresh transport and E2EE handshake can recover.
            closeLocked(unauthorized: false)
            return
        }
        if !opened {
            opened = true
            onOpen?()
        }
        for message in batch.messages ?? [] {
            if closed { return }
            if let text = message.t {
                onText?(text)
            } else if let encoded = message.b {
                guard let wire = Data(base64Encoded: encoded) else {
                    closeLocked(unauthorized: false)
                    return
                }
                onBinary?(wire)
            }
        }
        if let next = batch.next { after = next }
        pollNext()
    }

    // MARK: - Uplink (on `queue`)

    private func drainSendsLocked() {
        guard !closed, !suspended, !sendInFlight, !pendingWires.isEmpty else { return }
        var body = Data()
        var batched = 0
        while batched < Self.maximumWiresPerBatch,
              let wire = pendingWires.first,
              body.isEmpty || body.count + 4 + wire.count <= Self.maximumBatchBytes
        {
            var length = UInt32(wire.count).bigEndian
            withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
            body.append(wire)
            pendingWires.removeFirst()
            batched += 1
        }
        sendInFlight = true
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.sendTimeout
        request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.handleSendResult(response: response, error: error)
            }
        }
        task.resume()
    }

    private func handleSendResult(response: URLResponse?, error: Error?) {
        sendInFlight = false
        guard !closed else { return }
        guard error == nil, let status = (response as? HTTPURLResponse)?.statusCode else {
            // A send caught by the platform suspension is expected; the batch
            // is lost, but the owner refreshes with a replay on resume.
            if suspended { return }
            closeLocked(unauthorized: false)
            return
        }
        guard status == 204 else {
            closeLocked(unauthorized: status == 401 || status == 403)
            return
        }
        drainSendsLocked()
    }

    private func closeLocked(unauthorized: Bool) {
        guard !closed else { return }
        closed = true
        pollTask = nil
        urlSession.invalidateAndCancel()
        onClosed?(unauthorized)
    }
}
