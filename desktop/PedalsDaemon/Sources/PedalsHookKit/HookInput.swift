import Darwin
import Foundation

/// Bounded stdin reader for coding-agent hooks. Hook hosts normally write one
/// JSON document and close the pipe, but a host bug or inherited open writer
/// must never keep the agent waiting for EOF.
public enum HookInput {
    public static func read(
        fd: Int32 = STDIN_FILENO,
        cap: Int = 1 << 20,
        budgetMilliseconds: Int32 = 100
    ) -> Data {
        guard cap > 0, budgetMilliseconds > 0 else { return Data() }
        let originalFlags = fcntl(fd, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
            }
        }

        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(budgetMilliseconds) * 1_000_000
        var input = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while input.count < cap {
            let n = Darwin.read(fd, &chunk, min(chunk.count, cap - input.count))
            if n > 0 {
                input.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { break }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remaining = Int32(
                min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000)
            )
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&pollFD, 1, remaining)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { break }
        }
        return input
    }
}
