import TTYBuildKit
import UIKit

/// Bottom sheet asking the user to approve one computer that claimed this
/// phone's enrollment token. Confirmation is the security gate of reverse
/// pairing, so the card always names the computer and offers an explicit
/// rejection. The presenting page owns the network work and drives the sheet
/// through `show(_:)`; the sheet only reports button taps.
@MainActor
final class ReversePairingConfirmViewController: UIViewController {
    enum Phase {
        case deciding(claim: ReversePairingClaim, remaining: Int)
        case working(name: String)
        case failed(message: String)
    }

    var onConfirm: ((ReversePairingClaim) -> Void)?
    var onReject: ((ReversePairingClaim) -> Void)?
    var onDismissed: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let confirmButton = UIButton(type: .system)
    private let rejectButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private var phase: Phase

    init(claim: ReversePairingClaim, remaining: Int = 0) {
        phase = .deciding(claim: claim, remaining: remaining)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        isModalInPresentation = false
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
        view.accessibilityIdentifier = "ttybuild.reversePairing.card"

        let icon = UIImageView(
            image: UIImage(
                systemName: "laptopcomputer.and.iphone",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            )
        )
        icon.tintColor = TTYBuildTheme.uiContent
        icon.contentMode = .scaleAspectFit
        let iconRow = UIStackView(arrangedSubviews: [icon, UIView()])
        iconRow.axis = .horizontal

        titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(
            for: .systemFont(ofSize: 20, weight: .bold)
        )
        titleLabel.textColor = TTYBuildTheme.uiContent
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = TTYBuildTheme.uiSecondaryContent
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0

        spinner.color = TTYBuildTheme.uiSecondaryContent
        spinner.hidesWhenStopped = true
        let spinnerRow = UIStackView(arrangedSubviews: [spinner, UIView()])
        spinnerRow.axis = .horizontal

        var confirmConfiguration = UIButton.Configuration.borderedProminent()
        confirmConfiguration.cornerStyle = .large
        confirmConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 18, bottom: 14, trailing: 18
        )
        confirmConfiguration.baseBackgroundColor = TTYBuildTheme.uiContent
        confirmConfiguration.baseForegroundColor = TTYBuildTheme.uiCanvas
        TTYBuildTheme.applyTextFont(to: &confirmConfiguration, emphasized: true)
        confirmButton.configuration = confirmConfiguration
        confirmButton.accessibilityIdentifier = "ttybuild.reversePairing.confirm"
        confirmButton.addAction(
            UIAction { [weak self] _ in self?.confirmTapped() },
            for: .primaryActionTriggered
        )

        var rejectConfiguration = UIButton.Configuration.gray()
        rejectConfiguration.cornerStyle = .large
        rejectConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 18, bottom: 14, trailing: 18
        )
        rejectConfiguration.baseForegroundColor = TTYBuildTheme.uiCritical
        TTYBuildTheme.applyTextFont(to: &rejectConfiguration)
        rejectButton.configuration = rejectConfiguration
        rejectButton.accessibilityIdentifier = "ttybuild.reversePairing.reject"
        rejectButton.addAction(
            UIAction { [weak self] _ in self?.rejectTapped() },
            for: .primaryActionTriggered
        )

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        contentStack.setCustomSpacing(16, after: iconRow)
        for subview in [
            iconRow, titleLabel, messageLabel, spinnerRow, confirmButton, rejectButton,
        ] {
            contentStack.addArrangedSubview(subview)
        }
        contentStack.setCustomSpacing(20, after: spinnerRow)
        contentStack.setCustomSpacing(10, after: confirmButton)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismissed?()
    }

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
        case .deciding(let claim, let remaining):
            titleLabel.text = "“\(claim.computerName)” wants to connect"
            let date = Date(timeIntervalSince1970: TimeInterval(claim.createdAt))
            let when = date.formatted(date: .abbreviated, time: .shortened)
            var message = """
                This computer ran your install command (\(when)) and is \
                waiting to pair with this iPhone. Only confirm a computer \
                you set up yourself.
                """
            if remaining > 0 {
                message += "\n\(remaining) more computer\(remaining == 1 ? "" : "s") waiting."
            }
            messageLabel.text = message
            spinner.stopAnimating()
            confirmButton.configuration?.title = "Connect"
            setButtons(hidden: false)
            isModalInPresentation = false
        case .working(let name):
            titleLabel.text = "Connecting “\(name)”…"
            messageLabel.text = "Unsealing the computer's encrypted key…"
            spinner.startAnimating()
            setButtons(hidden: true)
            isModalInPresentation = true
        case .failed(let message):
            titleLabel.text = "Couldn't complete pairing"
            messageLabel.text = message
            spinner.stopAnimating()
            confirmButton.configuration?.title = "Try Again"
            setButtons(hidden: false)
            isModalInPresentation = false
        }
    }

    private func setButtons(hidden: Bool) {
        confirmButton.isHidden = hidden
        rejectButton.isHidden = hidden
        rejectButton.configuration?.title = "Don't Allow"
    }

    private var decidingClaim: ReversePairingClaim?

    private func confirmTapped() {
        guard let claim = claimForAction() else { return }
        onConfirm?(claim)
    }

    private func rejectTapped() {
        guard let claim = claimForAction() else { return }
        onReject?(claim)
    }

    private func claimForAction() -> ReversePairingClaim? {
        if case .deciding(let claim, _) = phase {
            decidingClaim = claim
            return claim
        }
        // "Try Again" after a failure retries the same claim.
        return decidingClaim
    }

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
}
