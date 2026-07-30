import SwiftUI

/// The fixed visual vocabulary shared by the app and every system surface.
///
/// Pedals is intentionally monochrome. Color is reserved for states where it
/// carries information that shape and copy alone cannot communicate quickly:
/// orange for degraded/stale data, and red for errors or destructive actions.
enum PedalsTheme {
    static let canvas = Color.black
    static let content = Color.white
    static let secondaryContent = Color.white.opacity(0.64)
    static let tertiaryContent = Color.white.opacity(0.38)
    static let surface = Color.white.opacity(0.08)
    static let separator = Color.white.opacity(0.16)
    static let selection = Color.white.opacity(0.18)

    static let warning = Color.orange
    static let critical = Color.red
    static let success = Color.green
}

#if os(iOS)
import UIKit

@MainActor
extension PedalsTheme {
    static var uiTextFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 16, weight: .regular)
        )
    }

    static var uiEmphasizedTextFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 16, weight: .semibold)
        )
    }

    static func applyTextFont(
        to configuration: inout UIButton.Configuration,
        emphasized: Bool = false
    ) {
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = emphasized ? uiEmphasizedTextFont : uiTextFont
            return outgoing
        }
    }

    static let uiCanvas = UIColor.black
    static let uiContent = UIColor.white
    static let uiSecondaryContent = UIColor.white.withAlphaComponent(0.64)
    static let uiTertiaryContent = UIColor.white.withAlphaComponent(0.38)
    static let uiSurface = UIColor.white.withAlphaComponent(0.08)
    static let uiSeparator = UIColor.white.withAlphaComponent(0.16)
    static let uiSelection = UIColor.white.withAlphaComponent(0.18)

    static let uiWarning = UIColor.systemOrange
    static let uiCritical = UIColor.systemRed
    static let uiSuccess = UIColor.systemGreen
}
#endif
