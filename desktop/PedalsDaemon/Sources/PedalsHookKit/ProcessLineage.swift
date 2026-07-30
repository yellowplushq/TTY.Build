import Darwin
import Foundation

/// One ancestor of the reporting process: enough for the daemon to locate the
/// agent process, its tty, and its terminal app.
public struct LineageEntry: Equatable, Sendable {
    public var pid: Int32
    /// Kernel `p_comm`, truncated to 16 bytes by the kernel.
    public var name: String
    /// Controlling terminal device path ("/dev/ttys003"), nil if none.
    public var tty: String?

    public init(pid: Int32, name: String, tty: String? = nil) {
        self.pid = pid
        self.name = name
        self.tty = tty
    }
}

/// Ancestor walk via `sysctl KERN_PROC_PID`, used by the hook reporter so the
/// daemon can match the agent against PTYs it owns
/// (docs/AGENT_MONITORING_DESIGN.md §4, ownership rule).
public enum ProcessLineage {
    /// Walks parent links starting *at* `startPid` (default: our parent, i.e.
    /// the shell Claude used to run the hook) for up to `maxDepth` levels.
    public static func walk(
        from startPid: pid_t = getppid(), maxDepth: Int = 15
    ) -> [LineageEntry] {
        var entries: [LineageEntry] = []
        var pid = startPid
        while entries.count < maxDepth, pid > 0 {
            guard let (entry, ppid) = info(for: pid) else { break }
            entries.append(entry)
            guard ppid > 0, ppid != pid else { break }
            pid = ppid
        }
        return entries
    }

    static func info(for pid: pid_t) -> (entry: LineageEntry, ppid: pid_t)? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        guard !name.isEmpty else { return nil }
        var tty: String?
        let device = proc.kp_eproc.e_tdev
        if device != -1, let deviceName = devname(device, mode_t(S_IFCHR)) {
            tty = "/dev/" + String(cString: deviceName)
        }
        return (
            LineageEntry(pid: pid, name: name, tty: tty),
            proc.kp_eproc.e_ppid
        )
    }
}
