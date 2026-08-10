import SwiftUI

/// macOS counterpart to the Apple mobile palette. The menu follows the
/// system's light/dark appearance while keeping the accent monochrome.
enum TTYBuildTheme {
    static let text = Font.body
    static let emphasizedText = Font.body.weight(.semibold)

    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let content = Color.primary
    static let secondaryContent = Color.secondary
    static let tertiaryContent = Color.primary.opacity(0.38)
    static let surface = Color.primary.opacity(0.065)
    static let separator = Color.primary.opacity(0.14)
    static let selection = Color.primary.opacity(0.17)

    static let warning = Color.orange
    static let critical = Color.red
}
