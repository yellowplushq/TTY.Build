import Darwin
import Foundation

/// Fire-and-forget client for the daemon's unix control socket. Everything is
/// best-effort and silent: a hook reporter must never disturb the agent that
/// invoked it, so all failures are swallowed.
public enum HookSocket {
    /// `$TTYBUILD_HOME/ttybuild.sock`, else `~/.tty.build/ttybuild.sock`.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let home = environment["TTYBUILD_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("ttybuild.sock").path
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tty.build", isDirectory: true)
            .appendingPathComponent("ttybuild.sock").path
    }

    /// Connects and writes within one small shared budget, then closes without
    /// waiting for a reply. The daemon treats hook requests as fire-and-forget;
    /// its acknowledgement must never sit on a coding agent's critical path.
    @discardableResult
    public static func send(
        _ line: Data,
        socketPath: String,
        budgetMilliseconds: Int32 = 100
    ) -> Bool {
        guard budgetMilliseconds > 0 else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(budgetMilliseconds) * 1_000_000

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }

        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return false }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, remainingMilliseconds(until: deadline)) == 1 else {
                return false
            }
            var socketError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorSize) == 0,
                  socketError == 0
            else { return false }
        }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let written = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    guard poll(
                        &pollFD, 1, remainingMilliseconds(until: deadline)
                    ) == 1 else { return false }
                    continue
                }
                return false
            }
            return true
        }
        guard written else { return false }
        _ = shutdown(fd, SHUT_WR)
        return true
    }

    private static func remainingMilliseconds(until deadline: UInt64) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return 0 }
        return Int32(
            min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000)
        )
    }
}
