// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TTYBuildKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .library(name: "TTYBuildKit", targets: ["TTYBuildKit"])
    ],
    targets: [
        .target(name: "TTYBuildKit"),
        .testTarget(name: "TTYBuildKitTests", dependencies: ["TTYBuildKit"]),
    ]
)
