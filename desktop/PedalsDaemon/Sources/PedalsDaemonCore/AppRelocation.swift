import Foundation

/// Decides whether (and how) the app should move itself into an Applications
/// folder on launch. Pure policy — the caller gathers filesystem facts and
/// performs the copy/delete/relaunch, so every rule here is unit-testable.
public enum AppRelocation {
    public struct Plan: Equatable, Sendable {
        public let sourceURL: URL
        public let destinationURL: URL
        /// False when the source volume is read-only (running from a DMG):
        /// the copy still happens, the original just cannot be removed.
        public let deleteSource: Bool
    }

    /// Path fragments that identify a build or archive location rather than
    /// a user install; relocating those would hijack development runs.
    private static let developmentMarkers = [
        "/DerivedData/", "/Build/Products/", ".xcarchive/",
    ]

    public static func plan(
        bundleURL: URL,
        systemApplicationsWritable: Bool,
        sourceVolumeReadOnly: Bool,
        homeDirectory: URL
    ) -> Plan? {
        let source = bundleURL.standardizedFileURL
        guard source.pathExtension == "app" else { return nil }

        // Already inside any Applications directory (system, user, or a
        // nested subfolder the user chose) — nothing to do.
        if source.pathComponents.contains("Applications") { return nil }

        let path = source.path
        if developmentMarkers.contains(where: { path.contains($0) }) { return nil }

        let destinationDirectory = systemApplicationsWritable
            ? URL(fileURLWithPath: "/Applications", isDirectory: true)
            : homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        let destination = destinationDirectory
            .appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard destination.standardizedFileURL != source else { return nil }

        return Plan(
            sourceURL: source,
            destinationURL: destination,
            deleteSource: !sourceVolumeReadOnly
        )
    }
}
