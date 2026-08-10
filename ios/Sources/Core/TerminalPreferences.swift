import Foundation
import GhosttyTerminal
import GhosttyTheme
import UIKit

enum TerminalCanvasLayout {
    static let horizontalPadding = 6
    static let verticalPadding = 4

    static var contentInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: CGFloat(verticalPadding),
            left: CGFloat(horizontalPadding),
            bottom: CGFloat(verticalPadding),
            right: CGFloat(horizontalPadding)
        )
    }
}

/// User-adjustable terminal appearance (Settings): font size + background.
/// The Ghostty theme itself is fixed to `defaultThemeName`.
@MainActor
final class TerminalPreferences {
    private enum Keys {
        static let fontSize = "terminal.fontSize"
        static let backgroundHex = "terminal.backgroundHex"
    }

    static let fontSizeRange: ClosedRange<Float> = 8 ... 24
    static let defaultFontSize: Float = 10
    static let defaultThemeName = "Catppuccin Mocha"

    private let defaults = UserDefaults.standard

    var fontSize: Float {
        get {
            let stored = defaults.float(forKey: Keys.fontSize)
            guard stored > 0 else { return Self.defaultFontSize }
            return stored.clamped(to: Self.fontSizeRange)
        }
        set { defaults.set(newValue.clamped(to: Self.fontSizeRange), forKey: Keys.fontSize) }
    }

    var themeDefinition: GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: Self.defaultThemeName)
    }

    /// Terminal background override: "#RRGGBB", or nil to follow the theme.
    /// Never-set defaults to pure black; stored "" means "follow theme".
    var backgroundHex: String? {
        get {
            guard let stored = defaults.string(forKey: Keys.backgroundHex) else {
                return "#000000"
            }
            return stored.isEmpty ? nil : stored
        }
        set { defaults.set(newValue ?? "", forKey: Keys.backgroundHex) }
    }

    /// Terminals stay dark-first: the chosen theme applies to both appearances.
    /// A background override must be applied to the theme itself — the theme
    /// wins over plain configuration values.
    func terminalTheme() -> TerminalTheme {
        var theme = themeDefinition?.toTerminalTheme() ?? .default
        guard let hex = backgroundHex else { return theme }
        theme.light = TerminalConfiguration(startingFrom: theme.light) {
            $0.withBackground(hex)
        }
        theme.dark = TerminalConfiguration(startingFrom: theme.dark) {
            $0.withBackground(hex)
        }
        return theme
    }

    /// The effective terminal canvas color, so app chrome can match it.
    var backgroundColor: UIColor {
        if let hex = backgroundHex, let color = UIColor(hex: hex) { return color }
        return themeDefinition.flatMap { UIColor(hex: $0.background) } ?? TTYBuildTheme.uiCanvas
    }

    func terminalConfiguration() -> TerminalConfiguration {
        TerminalConfiguration {
            $0.withFontSize(fontSize)
            $0.withWindowPaddingX(TerminalCanvasLayout.horizontalPadding)
            $0.withWindowPaddingY(TerminalCanvasLayout.verticalPadding)
            // Pure-black canvas regardless of the chosen theme's background.
            $0.withBackground("#000000")
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension UIColor {
    /// Parses "RRGGBB" / "#RRGGBB"; used for the background swatch.
    convenience init?(hex: String) {
        let hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard hex.count == 6,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
