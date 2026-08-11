import UIKit

/// Full-terminal freeze mask: dims the (stale) grid, swallows touches, and
/// shows a spinner + status line. Used while a terminal's data channel is
/// connecting / reconnecting after a network drop, and as the full-screen
/// exclusivity placeholder while another surface holds the session
/// (docs/EXCLUSIVE_ATTACH_DESIGN.md §5) — tap to take over.
final class TerminalStatusOverlay: UIView {
    enum Mode: Equatable {
        case hidden
        /// First connect / waking a pooled-out terminal.
        case connecting
        /// Was live; the link dropped and is retrying with backoff.
        case reconnecting
        /// Another surface holds the session; tap claims it back.
        case takenOver(name: String?)
        /// A holder-aware daemon reports nobody holding; tap attaches.
        case unheld
    }

    /// Fired on tap while in `takenOver`/`unheld`.
    var onClaim: (() -> Void)?

    private let dim = UIView()
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let placeholderStack = UIStackView()
    private let placeholderTitle = UILabel()
    private let placeholderAction = UILabel()

    private(set) var mode: Mode = .hidden

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true

        // The mask must freeze the terminal: swallow all touches while shown.
        isUserInteractionEnabled = true

        dim.backgroundColor = TTYBuildTheme.uiCanvas.withAlphaComponent(0.45)
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)

        card.backgroundColor = TTYBuildTheme.uiCanvas.withAlphaComponent(0.72)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        spinner.color = TTYBuildTheme.uiContent
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = TTYBuildTheme.uiContent
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        // Full-screen exclusivity placeholder (black/white, no spinner).
        placeholderTitle.font = .preferredFont(forTextStyle: .headline)
        placeholderTitle.textColor = TTYBuildTheme.uiContent
        placeholderTitle.textAlignment = .center
        placeholderTitle.numberOfLines = 2
        placeholderAction.font = .preferredFont(forTextStyle: .footnote)
        placeholderAction.textColor = TTYBuildTheme.uiContent.withAlphaComponent(0.6)
        placeholderAction.textAlignment = .center
        placeholderStack.axis = .vertical
        placeholderStack.alignment = .center
        placeholderStack.spacing = 8
        placeholderStack.isHidden = true
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderStack.addArrangedSubview(placeholderTitle)
        placeholderStack.addArrangedSubview(placeholderAction)
        addSubview(placeholderStack)

        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            placeholderStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 24
            ),
            placeholderStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -24
            ),
        ])

        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .hidden:
            isHidden = true
            spinner.stopAnimating()
            placeholderStack.isHidden = true
        case .connecting:
            show(text: "Connecting…")
        case .reconnecting:
            show(text: "Connection lost — reconnecting…")
        case .takenOver(let name):
            showPlaceholder(
                title: "In use on \(name ?? "another device")",
                action: "Tap to take over"
            )
        case .unheld:
            showPlaceholder(title: "Not attached", action: "Tap to attach")
        }
    }

    private func show(text: String) {
        label.text = text
        spinner.startAnimating()
        isHidden = false
        card.isHidden = false
        placeholderStack.isHidden = true
        dim.backgroundColor = TTYBuildTheme.uiCanvas.withAlphaComponent(0.45)
    }

    private func showPlaceholder(title: String, action: String) {
        placeholderTitle.text = title
        placeholderAction.text = action
        spinner.stopAnimating()
        card.isHidden = true
        placeholderStack.isHidden = false
        isHidden = false
        // Near-opaque: the stale grid underneath is not this surface's truth
        // while someone else drives the PTY.
        dim.backgroundColor = TTYBuildTheme.uiCanvas.withAlphaComponent(0.92)
    }

    @objc private func handleTap() {
        switch mode {
        case .takenOver, .unheld:
            onClaim?()
        case .hidden, .connecting, .reconnecting:
            break
        }
    }
}
