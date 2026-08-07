import Foundation
import Observation
import PedalsKit

@MainActor
@Observable
final class WatchTerminalSession {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
    }

    private(set) var descriptor: WatchTerminalDescriptor
    private(set) var phase: Phase = .idle
    private(set) var snapshot: TerminalTextProjection.Snapshot

    @ObservationIgnored private let binding: ComputerBinding
    @ObservationIgnored private let identity: ClientIdentity
    /// nil when the directory carried an ID outside the protocol's u32 space;
    /// such a session can never connect, but it must not trap either.
    @ObservationIgnored private let sessionID: UInt32?
    @ObservationIgnored private var link: RelayLink?
    @ObservationIgnored private var pipeline: WatchTerminalParserPipeline?
    @ObservationIgnored private var everLive = false

    init(
        descriptor: WatchTerminalDescriptor,
        binding: ComputerBinding,
        identity: ClientIdentity
    ) {
        self.descriptor = descriptor
        self.binding = binding
        self.identity = identity
        sessionID = UInt32(exactly: descriptor.id.sessionID)
        snapshot = TerminalTextProjection(
            cols: descriptor.cols,
            rows: descriptor.rows
        ).snapshot
    }

    func update(descriptor: WatchTerminalDescriptor) {
        let dimensionsChanged = descriptor.cols != self.descriptor.cols
            || descriptor.rows != self.descriptor.rows
        self.descriptor = descriptor
        if dimensionsChanged {
            pipeline?.resize(cols: descriptor.cols, rows: descriptor.rows)
        }
    }

    func start() {
        guard let sessionID else { return }
        guard link == nil else {
            link?.kick()
            return
        }
        if pipeline == nil {
            pipeline = WatchTerminalParserPipeline(
                cols: descriptor.cols,
                rows: descriptor.rows
            ) { [weak self] snapshot in
                Task { @MainActor in self?.snapshot = snapshot }
            }
        }

        phase = .connecting
        let link = RelayLink(
            computer: binding,
            authorization: identity.clientToken,
            role: .client,
            principalID: identity.clientID,
            channel: .session(sid: sessionID)
        )
        link.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state: state) }
        }
        link.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame: frame) }
        }
        link.onMetadata = { [weak self] metadata in
            MainActor.assumeIsolated { self?.handle(metadata: metadata) }
        }
        self.link = link
        link.start()
    }

    func stop() {
        link?.stop()
        link = nil
        phase = .idle
    }

    /// Wrist-down: park the link with its E2EE state intact instead of
    /// tearing it down, so the next wake usually needs no handshake.
    func suspend() {
        link?.suspend()
    }

    /// Wrist-up: continue the parked link and refresh the grid. The replay
    /// covers anything dropped while the relay queued (or overflowed) during
    /// the suspension; if the link died, `resume()` redials and the handshake
    /// replay makes this request redundant but harmless.
    func resume() {
        guard let link else {
            start()
            return
        }
        link.resume()
        link.send(.requestReplay)
    }

    private func handle(state: RelayLink.State) {
        switch state {
        case .idle:
            break
        case .connected:
            break // replay marks the session live
        case .connecting:
            phase = everLive ? .reconnecting : .connecting
        }
    }

    private func handle(frame: Frame) {
        if (frame.type == .replay || frame.type == .stdout || frame.type == .resize),
           frame.sessionId != sessionID
        {
            return
        }
        switch frame.type {
        case .replay:
            pipeline?.receive(frame.payload, reset: true)
            everLive = true
            phase = .live
        case .stdout:
            guard phase == .live else { return }
            pipeline?.receive(frame.payload, reset: false)
        case .resize:
            guard let size = try? frame.resizeSize() else { return }
            pipeline?.resize(cols: Int(size.cols), rows: Int(size.rows))
        case .ctl, .stdin:
            break
        }
    }

    private func handle(metadata: RelayMetadata) {
        guard case .channelState(let online) = metadata, !online else { return }
        if everLive { phase = .reconnecting }
    }
}

private final class WatchTerminalParserPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "air.build.pedals.watch-terminal-parser")
    private let onSnapshot: @Sendable (TerminalTextProjection.Snapshot) -> Void
    private var projection: TerminalTextProjection
    private var flushScheduled = false

    init(
        cols: Int,
        rows: Int,
        onSnapshot: @escaping @Sendable (TerminalTextProjection.Snapshot) -> Void
    ) {
        projection = TerminalTextProjection(cols: cols, rows: rows)
        self.onSnapshot = onSnapshot
    }

    func receive(_ data: Data, reset: Bool) {
        queue.async { [self] in
            if reset { projection.reset() }
            projection.feed(data)
            scheduleFlush()
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [self] in
            projection.resize(cols: cols, rows: rows)
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            flushScheduled = false
            onSnapshot(projection.snapshot)
        }
    }
}
