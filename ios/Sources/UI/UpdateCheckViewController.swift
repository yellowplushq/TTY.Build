import UIKit

/// Bottom-sheet mirror of the Mac's Sparkle "Software Update" dialog, built
/// from mobile components: app mark, bold headline, detail copy, and
/// full-width actions. The presenting page owns all protocol traffic and
/// drives the sheet through `show(_:)`; the sheet only reports button taps.
@MainActor
final class UpdateCheckViewController: UIViewController {
    enum Phase {
        /// Waiting for the Mac's `update-status` reply.
        case checking(host: String)
        case upToDate(version: String?)
        case available(current: String?, latest: String?, host: String, canInstall: Bool)
        /// Waiting for the Mac's `update-install` reply.
        case installing(host: String)
        case started(message: String)
        case failed(title: String, message: String)
    }

    /// Fired by the Install Update button in the `.available` phase.
    var onInstall: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private var phase: Phase = .checking(host: "")

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [
                .custom { [weak self] _ in self?.preferredSheetHeight() }
            ]
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.preferredCornerRadius = 28
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        let icon = UIImageView(image: UIImage(named: "AppMark"))
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 14
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])
        let iconRow = UIStackView(arrangedSubviews: [icon, UIView()])
        iconRow.axis = .horizontal

        titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(
            for: .systemFont(ofSize: 20, weight: .bold)
        )
        titleLabel.textColor = PedalsTheme.uiContent
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = PedalsTheme.uiSecondaryContent
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0

        spinner.color = PedalsTheme.uiSecondaryContent
        spinner.hidesWhenStopped = true
        let spinnerRow = UIStackView(arrangedSubviews: [spinner, UIView()])
        spinnerRow.axis = .horizontal

        primaryButton.configuration = Self.primaryConfiguration()
        primaryButton.addAction(
            UIAction { [weak self] _ in self?.primaryTapped() },
            for: .primaryActionTriggered
        )
        secondaryButton.configuration = Self.secondaryConfiguration()
        secondaryButton.addAction(
            UIAction { [weak self] _ in self?.dismiss(animated: true) },
            for: .primaryActionTriggered
        )

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        contentStack.setCustomSpacing(16, after: iconRow)
        for subview in [iconRow, titleLabel, messageLabel, spinnerRow, primaryButton, secondaryButton] {
            contentStack.addArrangedSubview(subview)
        }
        contentStack.setCustomSpacing(20, after: spinnerRow)
        contentStack.setCustomSpacing(10, after: primaryButton)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        render()
    }

    // MARK: - Phase

    func show(_ phase: Phase) {
        self.phase = phase
        guard isViewLoaded else { return }
        render()
        if viewIfLoaded?.window != nil, let sheet = sheetPresentationController {
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    private func render() {
        switch phase {
        case .checking(let host):
            titleLabel.text = "Checking for Updates…"
            messageLabel.text = "Contacting \(host)…"
            spinner.startAnimating()
            setButtons(primary: nil, secondary: "Cancel")
        case .upToDate(let version):
            titleLabel.text = "You're up to date!"
            messageLabel.text = version.map {
                "Pedals \($0) is currently the newest version available."
            } ?? "Pedals on the Mac is currently the newest version available."
            spinner.stopAnimating()
            setButtons(primary: "OK", secondary: nil)
        case .available(let current, let latest, let host, let canInstall):
            titleLabel.text = "Update Available"
            let name = latest.map { "Pedals \($0)" } ?? "A new version of Pedals"
            let have = current.map { " — \(host) has \($0)" } ?? ""
            if canInstall {
                messageLabel.text = """
                    \(name) is available\(have). Installing restarts Pedals on \
                    the Mac and closes every open terminal session there.
                    """
                setButtons(primary: "Install Update", secondary: "Not Now")
            } else {
                messageLabel.text = "\(name) is available\(have). Install it from the Mac."
                setButtons(primary: "OK", secondary: nil)
            }
            spinner.stopAnimating()
        case .installing(let host):
            titleLabel.text = "Starting Update…"
            messageLabel.text = "Asking \(host) to start the update…"
            spinner.startAnimating()
            setButtons(primary: nil, secondary: nil)
        case .started(let message):
            titleLabel.text = "Update Started"
            messageLabel.text = message
            spinner.stopAnimating()
            setButtons(primary: "OK", secondary: nil)
        case .failed(let title, let message):
            titleLabel.text = title
            messageLabel.text = message
            spinner.stopAnimating()
            setButtons(primary: "OK", secondary: nil)
        }
    }

    private func setButtons(primary: String?, secondary: String?) {
        primaryButton.isHidden = primary == nil
        if let primary {
            primaryButton.configuration?.title = primary
        }
        secondaryButton.isHidden = secondary == nil
        if let secondary {
            secondaryButton.configuration?.title = secondary
        }
    }

    private func primaryTapped() {
        if case .available(_, _, _, true) = phase {
            onInstall?()
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: - Sizing

    private func preferredSheetHeight() -> CGFloat {
        loadViewIfNeeded()
        let width = view.bounds.width > 0
            ? view.bounds.width
            : view.window?.bounds.width ?? 393
        let fitting = contentStack.systemLayoutSizeFitting(
            CGSize(width: width - 40, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return fitting.height + 24 + 16
    }

    // MARK: - Button styles

    private static func primaryConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 18, bottom: 14, trailing: 18
        )
        configuration.baseBackgroundColor = PedalsTheme.uiContent
        configuration.baseForegroundColor = PedalsTheme.uiCanvas
        PedalsTheme.applyTextFont(to: &configuration, emphasized: true)
        return configuration
    }

    private static func secondaryConfiguration() -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 18, bottom: 14, trailing: 18
        )
        configuration.baseForegroundColor = PedalsTheme.uiContent
        PedalsTheme.applyTextFont(to: &configuration)
        return configuration
    }
}
