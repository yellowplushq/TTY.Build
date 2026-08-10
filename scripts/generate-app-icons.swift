#!/usr/bin/env swift

import AppKit
import Foundation

private enum IconError: Error, CustomStringConvertible {
    case invalidMaster(String)
    case bitmapCreation(Int, Int)
    case pngEncoding(String)

    var description: String {
        switch self {
        case .invalidMaster(let path): "Could not load the icon master at \(path)"
        case .bitmapCreation(let width, let height):
            "Could not create a \(width)x\(height) bitmap"
        case .pngEncoding(let path): "Could not encode PNG at \(path)"
        }
    }
}

private let fileManager = FileManager.default
private let repositoryRoot = URL(
    fileURLWithPath: fileManager.currentDirectoryPath,
    isDirectory: true
)
private let masterURL = CommandLine.arguments.dropFirst().first.map {
    URL(fileURLWithPath: $0)
} ?? repositoryRoot.appendingPathComponent("brand/TTYBuildIconMaster.png")

guard let master = NSImage(contentsOf: masterURL), master.isValid else {
    FileHandle.standardError.write(Data("\(IconError.invalidMaster(masterURL.path))\n".utf8))
    exit(1)
}

private func makeBitmap(
    width: Int,
    height: Int,
    hasAlpha: Bool,
    drawing: () -> Void
) throws -> NSBitmapImageRep {
    let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
    guard let bitmapContext = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | alphaInfo.rawValue
    ) else {
        throw IconError.bitmapCreation(width, height)
    }

    let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    bitmapContext.setShouldAntialias(true)
    bitmapContext.setAllowsAntialiasing(true)
    drawing()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = bitmapContext.makeImage() else {
        throw IconError.bitmapCreation(width, height)
    }
    return NSBitmapImageRep(cgImage: image)
}

private func writePNG(_ bitmap: NSBitmapImageRep, to relativePath: String) throws {
    let url = repositoryRoot.appendingPathComponent(relativePath)
    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.pngEncoding(relativePath)
    }
    try data.write(to: url, options: .atomic)
}

private func squareIcon(size: Int) throws -> NSBitmapImageRep {
    try makeBitmap(width: size, height: size, hasAlpha: false) {
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.black.setFill()
        bounds.fill()
        master.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

/// macOS does not apply the same outer mask as iOS. Keep the supplied black
/// artwork inside the modern macOS rounded-square silhouette and leave a
/// transparent optical margin so Finder, Spotlight, and the Dock all match.
private func macIcon(size: Int) throws -> NSBitmapImageRep {
    try makeBitmap(width: size, height: size, hasAlpha: true) {
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvas.fill(using: .copy)

        let inset = CGFloat(size) * 0.075
        let badge = canvas.insetBy(dx: inset, dy: inset)
        let mask = NSBezierPath(
            roundedRect: badge,
            xRadius: CGFloat(size) * 0.205,
            yRadius: CGFloat(size) * 0.205
        )
        NSGraphicsContext.saveGraphicsState()
        mask.addClip()
        NSColor.black.setFill()
        badge.fill()
        master.draw(
            in: badge,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Menu bar images are template masks. Convert the white mark's luminance to
/// alpha and discard the black square so macOS can tint it for either menu bar
/// appearance and accessibility contrast setting.
private func menuBarTemplate(size: Int) throws -> NSBitmapImageRep {
    let bitmap = try makeBitmap(width: size, height: size, hasAlpha: true) {
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.black.setFill()
        bounds.fill()
        master.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    guard let data = bitmap.bitmapData else {
        throw IconError.bitmapCreation(size, size)
    }
    for y in 0 ..< size {
        for x in 0 ..< size {
            let offset = y * bitmap.bytesPerRow + x * 4
            let luminance = max(data[offset], data[offset + 1], data[offset + 2])
            let alpha: UInt8 = luminance <= 18
                ? 0
                : UInt8(min(255, Int(luminance - 18) * 255 / 237))
            data[offset] = 0
            data[offset + 1] = 0
            data[offset + 2] = 0
            data[offset + 3] = alpha
        }
    }
    return bitmap
}

private func socialCard() throws -> NSBitmapImageRep {
    try makeBitmap(width: 1200, height: 630, hasAlpha: false) {
        let bounds = NSRect(x: 0, y: 0, width: 1200, height: 630)
        NSColor.black.setFill()
        bounds.fill()

        let iconRect = NSRect(x: 315, y: 30, width: 570, height: 570)
        master.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

private func generateICO() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-s", "format", "ico",
        repositoryRoot.appendingPathComponent("relay/public/favicon-32.png").path,
        "--out",
        repositoryRoot.appendingPathComponent("relay/public/favicon.ico").path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw CocoaError(.fileWriteUnknown)
    }
}

do {
    // iOS, watchOS, and App Store Connect all consume the 1024 marketing icon.
    try writePNG(
        squareIcon(size: 1024),
        to: "ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    )
    try writePNG(
        squareIcon(size: 1024),
        to: "ios/WatchApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    )

    // In-app brand mark used by onboarding and the desktop popover header.
    for (size, scale) in [(64, "1x"), (128, "2x"), (192, "3x")] {
        try writePNG(
            squareIcon(size: size),
            to: "ios/Resources/Assets.xcassets/AppMark.imageset/AppMark-\(scale).png"
        )
    }
    for (size, scale) in [(32, "1x"), (64, "2x")] {
        try writePNG(
            squareIcon(size: size),
            to: "desktop/TTYBuildMenubar/Resources/Assets.xcassets/AppMark.imageset/AppMark-\(scale).png"
        )
    }

    // Complete macOS icon matrix for Finder, Dock, Spotlight, and About panels.
    let macOutputs: [(Int, String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for (size, filename) in macOutputs {
        try writePNG(
            macIcon(size: size),
            to: "desktop/TTYBuildMenubar/Resources/Assets.xcassets/AppIcon.appiconset/\(filename)"
        )
    }

    for (size, scale) in [(18, "1x"), (36, "2x")] {
        try writePNG(
            menuBarTemplate(size: size),
            to: "desktop/TTYBuildMenubar/Resources/Assets.xcassets/StatusBarIcon.imageset/StatusBarIcon-\(scale).png"
        )
    }

    // Website identity, install surfaces, browser tabs, and social previews.
    try writePNG(squareIcon(size: 128), to: "relay/public/brand-icon.png")
    try writePNG(squareIcon(size: 16), to: "relay/public/favicon-16.png")
    try writePNG(squareIcon(size: 32), to: "relay/public/favicon-32.png")
    try writePNG(squareIcon(size: 180), to: "relay/public/apple-touch-icon.png")
    try writePNG(squareIcon(size: 192), to: "relay/public/icon-192.png")
    try writePNG(squareIcon(size: 512), to: "relay/public/icon-512.png")
    try writePNG(socialCard(), to: "relay/public/og.png")
    try generateICO()

    print("Generated TTYBuild icons from \(masterURL.path)")
} catch {
    FileHandle.standardError.write(Data("app icon generation failed: \(error)\n".utf8))
    exit(1)
}
