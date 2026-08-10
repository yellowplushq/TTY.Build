import Combine
import Foundation
import TTYBuildKit

/// Identity of one terminal across all bound computers.
struct TerminalID: Hashable, Sendable {
    /// The server-issued computer identifier.
    let computerID: String
    /// The daemon-assigned session id within that computer.
    let sid: Int
}

/// One terminal's live data connection: a `session` channel WebSocket opened
/// lazily when the terminal is activated (PROTOCOL.md §3, frames per §5).
/// Connecting sends
/// `hello`, which makes the host replay scrollback and stream stdout; stdin
/// and resize go out on the same socket. Pooled by `TerminalManager` — the
/// least recently activated channels are stopped ("asleep") when too many
/// are open; the daemon keeps the PTY running regardless.
@MainActor
final class TerminalChannel {
    enum Phase: Equatable {
        /// Socket dialing / waiting for the host's first replay.
        case connecting
        /// Replay applied; live.
        case live
        /// Was live, connection lost; retrying with backoff.
        case reconnecting
    }

    let terminalID: TerminalID
    private(set) var phase: Phase = .connecting {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }

    var onPhase: ((Phase) -> Void)?
    /// The daemon's relay socket vanished and came back while our own link
    /// stayed up. Client→host frames sent in that window were dropped by the
    /// relay with no error, so the owner must re-announce idempotent state
    /// (the applied grid size).
    var onHostRestored: (() -> Void)?
    var onReplay: ((Data) -> Void)?
    var onStdout: ((Data) -> Void)?
    /// The daemon echoed an authoritative grid it applied (PROTOCOL.md §5).
    /// Used to detect another client resizing the PTY behind a hidden
    /// emulator, which invalidates the keep-fed background stream.
    var onResizeEcho: ((_ cols: UInt16, _ rows: UInt16) -> Void)?
    /// LRU stamp for the connection pool.
    private(set) var lastActivated = Date()

    private let link: RelayLink
    private var everLive = false
    private var peerLossTask: Task<Void, Never>?

    init(terminalID: TerminalID, link: RelayLink) {
        self.terminalID = terminalID
        self.link = link
        link.onState = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state: state) }
        }
        link.onFrame = { [weak self] frame in
            MainActor.assumeIsolated { self?.handle(frame: frame) }
        }
        link.onMetadata = { [weak self] metadata in
            MainActor.assumeIsolated {
                guard case .channelState(let online) = metadata else { return }
                self?.handle(hostPresent: online)
            }
        }
        link.start()
    }

    func touch() {
        lastActivated = Date()
    }

    func stop() {
        peerLossTask?.cancel()
        peerLossTask = nil
        link.stop()
    }

    func kick() {
        link.kick()
    }

    /// Ask the host for a fresh replay over the established E2EE channel.
    /// Used when the UI missed an earlier replay (e.g. the page was created
    /// after the channel already went live).
    func requestReplay() {
        link.send(.requestReplay)
    }

    func sendStdin(_ data: Data) {
        link.send(.stdin(sessionId: UInt32(terminalID.sid), data: data))
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        link.send(.resize(sessionId: UInt32(terminalID.sid), cols: cols, rows: rows))
    }

    private func handle(state: RelayLink.State) {
        switch state {
        case .connected:
            break // stays "connecting" until the host's replay lands
        case .connecting:
            peerLossTask?.cancel()
            peerLossTask = nil
            phase = everLive ? .reconnecting : .connecting
        case .idle:
            break
        }
    }

    /// Relay channel state: the daemon's socket appeared/vanished.
    /// Our own link can be healthy while the host end is gone (daemon quit) —
    /// without this the terminal would freeze with no overlay.
    private func handle(hostPresent: Bool) {
        if hostPresent {
            peerLossTask?.cancel()
            peerLossTask = nil
            guard everLive else { return }
            // While the host socket was gone the relay dropped our frames
            // without an error. A fresh replay resynchronizes the stream (and
            // flips a stuck `.reconnecting` back to `.live` — stdout is
            // discarded until a replay lands); `onHostRestored` lets the owner
            // re-announce the applied grid for blips too short to change phase.
            if phase != .live {
                link.send(.requestReplay)
            }
            onHostRestored?()
            return
        }
        guard phase == .live, peerLossTask == nil else { return }

        // The authoritative DO directory travels over the control socket. Give
        // it one render beat to remove a deliberately closed session before
        // showing a reconnect overlay for a real per-channel outage.
        peerLossTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.phase == .live else { return }
            self.peerLossTask = nil
            self.phase = .reconnecting
        }
    }

    private func handle(frame: Frame) {
        // Defense in depth: per-channel keys already stop cross-channel
        // ciphertext at decrypt, so a data frame whose sid isn't ours can only
        // be a bug — drop it rather than render another session's output here.
        if (frame.type == .replay || frame.type == .stdout || frame.type == .resize),
           frame.sessionId != UInt32(terminalID.sid) {
            return
        }
        switch frame.type {
        case .replay:
            peerLossTask?.cancel()
            peerLossTask = nil
            everLive = true
            phase = .live
            onReplay?(frame.payload)
        case .stdout:
            // Before the (re)connect replay lands, live stdout would paint onto
            // a grid that's missing everything dropped during the outage; the
            // replay covers those bytes, so drop them here.
            guard phase == .live else { break }
            onStdout?(frame.payload)
        case .ctl:
            break
        case .resize:
            // The iPhone owns this renderer's grid while its page is active,
            // so echoes never reconfigure the emulator. They still matter as
            // a signal: a grid we never applied means another client resized
            // the PTY and the stream no longer matches this emulator.
            guard let size = try? frame.resizeSize() else { break }
            onResizeEcho?(size.cols, size.rows)
        case .stdin:
            break // client→host only; ignore if mirrored back
        }
    }
}
