import AppKit
import PedalsDaemonCore

/// Moves the app into an Applications folder on launch when it was started
/// from anywhere else (Downloads, Desktop, a DMG…), then relaunches from the
/// new location and removes the original. The enrollment pairing stamp is an
/// extended attribute on the bundle, and both the copy below and Finder
/// copies preserve xattrs, so a stamped download still pairs after the move.
@MainActor
enum AppRelocator {
    /// Returns true when a relocation was started; the caller must skip the
    /// rest of its launch work, because the process terminates momentarily.
    static func relocateIfNeeded() -> Bool {
        #if DEBUG
        return false
        #else
        if ProcessInfo.processInfo.environment["PEDALS_NO_RELOCATE"] == "1" {
            return false
        }
        let fileManager = FileManager.default
        let bundleURL = originalBundleURL(for: Bundle.main.bundleURL)
        let volumeReadOnly = (try? bundleURL.resourceValues(
            forKeys: [.volumeIsReadOnlyKey]
        ).volumeIsReadOnly) ?? false
        guard let plan = AppRelocation.plan(
            bundleURL: bundleURL,
            systemApplicationsWritable: fileManager.isWritableFile(atPath: "/Applications"),
            sourceVolumeReadOnly: volumeReadOnly,
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        ) else { return false }

        // Another instance already running from the destination owns that
        // bundle; replacing it under a live process helps nobody.
        let runningElsewhere = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).contains { application in
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && application.bundleURL?.standardizedFileURL == plan.destinationURL
        }
        if runningElsewhere {
            NSLog("Pedals is already running from %@; not relocating", plan.destinationURL.path)
            return false
        }

        // Stage-and-swap exactly like the installer, so a failed copy can
        // never leave a half-written bundle in Applications.
        let staging = plan.destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(plan.destinationURL.lastPathComponent).moving")
        do {
            try fileManager.createDirectory(
                at: plan.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: staging)
            try fileManager.copyItem(at: plan.sourceURL, to: staging)
            try? fileManager.removeItem(at: plan.destinationURL)
            try fileManager.moveItem(at: staging, to: plan.destinationURL)
        } catch {
            try? fileManager.removeItem(at: staging)
            NSLog("Pedals could not move itself to Applications: %@", "\(error)")
            return false
        }

        // Start the relaunch helper before deleting anything: if it cannot
        // spawn, keep running from the original location instead of leaving
        // the moved copy installed but never launched.
        guard startRelaunchHelper(at: plan.destinationURL) else {
            try? fileManager.removeItem(at: plan.destinationURL)
            NSLog("Pedals could not relaunch from Applications; continuing in place")
            return false
        }
        if plan.deleteSource {
            do {
                try fileManager.removeItem(at: plan.sourceURL)
            } catch {
                NSLog("Pedals moved to Applications but could not remove %@", plan.sourceURL.path)
            }
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return true
        #endif
    }

    /// A quarantined app launched in place runs from a randomized read-only
    /// App Translocation mount; resolve the user-visible original so the
    /// right bundle gets copied and removed. Security ships the resolver as
    /// SPI, so it is loaded dynamically and any failure falls back safely.
    private static func originalBundleURL(for bundleURL: URL) -> URL {
        guard bundleURL.path.contains("/AppTranslocation/") else { return bundleURL }
        typealias Resolver = @convention(c) (
            CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFURL>?
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY
            ),
            let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
        else { return bundleURL }
        let resolve = unsafeBitCast(symbol, to: Resolver.self)
        guard let original = resolve(bundleURL as CFURL, nil)?.takeRetainedValue() else {
            return bundleURL
        }
        return (original as URL).standardizedFileURL
    }

    /// Spawns a detached helper that waits for this process to exit, then
    /// opens the moved copy. Waiting first means LaunchServices sees one
    /// instance, not a relaunch racing a shutdown.
    private static func startRelaunchHelper(at destination: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done
        /usr/bin/open "$0"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, destination.path]
        do {
            try process.run()
            return true
        } catch {
            NSLog("Pedals could not start its relaunch helper: %@", "\(error)")
            return false
        }
    }
}
