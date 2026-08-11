// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TTYBuildDaemon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TTYBuildDaemonCore", targets: ["TTYBuildDaemonCore"]),
        // Internal debugging only — not part of external releases.
        .executable(name: "ttybuild", targets: ["ttybuild"]),
        // Coding-agent hook reporter, installed to ~/.tty.build/bin by
        // `ttybuild hooks install` / the menu bar app.
        .executable(name: "ttybuild-hook", targets: ["ttybuild-hook"]),
        // Shipped attach-only client (docs/EXCLUSIVE_ATTACH_DESIGN.md §7):
        // embedded in the menu bar app bundle and symlinked onto PATH by
        // "Install command line tool". Attach/claim/detach only — none of
        // the debug CLI's serve/pair/reset surface.
        .executable(name: "ttybuild-attach", targets: ["ttybuild-attach"]),
    ],
    dependencies: [
        .package(path: "../../shared/TTYBuildKit"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CTTYBuildPTY",
            publicHeadersPath: "include"
        ),
        .target(
            name: "TTYBuildDaemonCore",
            dependencies: [
                "CTTYBuildPTY",
                "TTYBuildHookKit",
                .product(name: "TTYBuildKit", package: "TTYBuildKit")
            ]
        ),
        // Foundation + system SQLite logic for the hook reporter (stdin
        // mapping, Codex thread metadata, transcript scan, lineage walk,
        // wire encoding). No TTYBuildKit or AppKit: keep the reporter lean.
        .target(
            name: "TTYBuildHookKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ttybuild",
            dependencies: [
                "TTYBuildDaemonCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ttybuild-hook",
            dependencies: ["TTYBuildHookKit"]
        ),
        .executableTarget(
            name: "ttybuild-attach",
            dependencies: [
                "TTYBuildDaemonCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "TTYBuildDaemonCoreTests",
            dependencies: ["TTYBuildDaemonCore", "TTYBuildHookKit"]
        ),
        .testTarget(
            name: "TTYBuildHookKitTests",
            dependencies: ["TTYBuildHookKit"]
        ),
    ]
)
