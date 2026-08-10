import UIKit

/// Full-terminal freeze mask: dims the (stale) grid, swallows touches, and
/// shows a spinner + status line. Used while a terminal's data channel is
/// connecting / reconnecting after a network drop, and while a close is in
/// flight ("exiting" until the daemon's session list confirms removal).
final class TerminalStatusOverlay: UIView {
    enum Mode: Equatable {
        case hidden
        /// First connect / waking a pooled-out terminal.
        case connecting
        /// Was live; the link dropped and is retrying with backoff.
        case reconnecting
        /// `close` sent; waiting for the daemon to confirm.
        case closing
    }

    private let dim = UIView()
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

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
        ])
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
        case .connecting:
            show(text: "Connecting…")
        case .reconnecting:
            show(text: "Connection lost — reconnecting…")
        case .closing:
            show(text: "Closing terminal…")
        }
    }

    private func show(text: String) {
        label.text = text
        spinner.startAnimating()
        isHidden = false
    }
}
