@testable import TTYBuild
import Foundation
import GhosttyTerminal
import UIKit

/// A `TerminalHost` whose Ghostty surface is attached to a visible window, so
/// received bytes are parsed (and answered) instead of queued until a view
/// joins a window. Records every chunk the host sends to the PTY.
@MainActor
final class AttachedTerminalHost {
    let host = TerminalHost(controller: TerminalController())
    private(set) var inputs: [Data] = []
    private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

    init() {
        host.onInput = { [weak self] in self?.inputs.append($0) }

        let root = UIViewController()
        window.rootViewController = root
        host.view.frame = root.view.bounds
        root.view.addSubview(host.view)
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()

        // Let the surface attach and the initial size report settle.
        _ = Self.waitUntil(timeout: 0.5) { false }
        inputs.removeAll()
    }

    func tearDown() {
        window.isHidden = true
    }

    var containsDeviceAttributesReply: Bool {
        inputs.contains { chunk in
            chunk.starts(with: Data("\u{1b}[?".utf8)) && chunk.last == UInt8(ascii: "c")
        }
    }

    static func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
