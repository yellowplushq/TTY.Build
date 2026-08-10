import Foundation
import TTYBuildKit

/// The enrollment code a paired download or the install script leaves on the
/// app bundle as an extended attribute. Riding on the bundle (rather than a
/// URL scheme or a sidecar file) survives Finder copies, `ditto` zip
/// round-trips, and AirDrop, and never touches the code-signature seal.
///
/// The stamp is durable until consumed: the app claims it on launch, so an
/// install that finishes while an old TTYBuild is still running simply pairs
/// on the next relaunch.
public enum EnrollmentCodeStamp {
    public static let attributeName = "build.tty.pairing-code"

    /// Reads and validates the stamped code, or nil when absent/malformed.
    public static func read(bundleURL: URL) -> PairingCode? {
        let path = bundleURL.path
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0, size <= 64 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, attributeName, &buffer, buffer.count, 0, 0)
        guard read == size,
              let value = String(bytes: buffer, encoding: .utf8)
        else { return nil }
        return try? PairingCode(value)
    }

    /// Removes the stamp after a claim reached a terminal outcome. Fails
    /// silently on read-only bundles (e.g. a translocated launch) — the code
    /// is multi-use, so a later duplicate claim is harmless.
    public static func clear(bundleURL: URL) {
        removexattr(bundleURL.path, attributeName, 0)
    }
}
