import UIKit

/// First-run onboarding shown whenever this iPhone has no durable computer
/// binding. Pairing opens directly from this single page.
@MainActor
final class UnpairedStateView: UIView {
    var onEnterCode: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let hero = RemoteTerminalHeroView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TTYBuildTheme.uiCanvas
        accessibilityIdentifier = "ttybuild.onboarding"
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureLayout() {
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let header = makeBrandHeader()
        hero.isAccessibilityElement = true
        hero.accessibilityLabel = "A computer terminal securely connected to an iPhone"
        let copy = makeWelcomeCopy()
        let flexibleSpacer = UIView()
        flexibleSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
        let pairButton = makePairButton()
        let footnote = makeLabel(
            "8-digit code · One use · 15 minutes",
            color: TTYBuildTheme.uiTertiaryContent,
            alignment: .center
        )

        [header, hero, copy, flexibleSpacer, pairButton, footnote].forEach(
            contentStack.addArrangedSubview
        )

        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        hero.heightAnchor.constraint(equalToConstant: 270).isActive = true
        copy.heightAnchor.constraint(equalToConstant: 88).isActive = true
        pairButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        footnote.heightAnchor.constraint(equalToConstant: 19).isActive = true

        contentStack.setCustomSpacing(12, after: header)
        contentStack.setCustomSpacing(8, after: hero)
        contentStack.setCustomSpacing(12, after: copy)
        contentStack.setCustomSpacing(18, after: flexibleSpacer)
        contentStack.setCustomSpacing(12, after: pairButton)

        let responsiveWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -64
        )
        responsiveWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 14
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -18
            ),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            responsiveWidth,
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor,
                constant: 32
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor,
                constant: -32
            ),
            contentStack.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor,
                constant: -32
            ),
        ])
    }

    private func makeBrandHeader() -> UIView {
        let mark = UIImageView(image: UIImage(named: "AppMark"))
        mark.contentMode = .scaleAspectFit
        mark.layer.cornerRadius = 12
        mark.layer.cornerCurve = .continuous
        mark.clipsToBounds = true
        mark.isAccessibilityElement = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 38),
            mark.heightAnchor.constraint(equalToConstant: 38),
        ])

        let title = makeLabel(
            "tty.build",
            color: TTYBuildTheme.uiContent,
            alignment: .left,
            emphasized: true
        )
        let privacyIcon = UIImageView(
            image: UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            )
        )
        privacyIcon.tintColor = TTYBuildTheme.uiSecondaryContent
        let privacyLabel = makeLabel(
            "Private",
            color: TTYBuildTheme.uiSecondaryContent,
            alignment: .left
        )
        privacyLabel.numberOfLines = 1

        let privacy = UIStackView(arrangedSubviews: [privacyIcon, privacyLabel])
        privacy.axis = .horizontal
        privacy.alignment = .center
        privacy.spacing = 6
        privacy.isLayoutMarginsRelativeArrangement = true
        privacy.layoutMargins = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        privacy.backgroundColor = TTYBuildTheme.uiSurface
        privacy.layer.cornerRadius = 16
        privacy.layer.cornerCurve = .continuous

        let row = UIStackView(arrangedSubviews: [mark, title, UIView(), privacy])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 11
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    private func makeWelcomeCopy() -> UIView {
        let title = makeLabel(
            "Your computer, within reach.",
            color: TTYBuildTheme.uiContent,
            alignment: .center,
            emphasized: true
        )
        title.accessibilityIdentifier = "ttybuild.onboarding.title"
        let body = makeLabel(
            "Use its terminals from iPhone, anywhere. tty.build keeps the connection end-to-end encrypted.",
            color: TTYBuildTheme.uiSecondaryContent,
            alignment: .center
        )

        let copy = UIStackView(arrangedSubviews: [title, body])
        copy.axis = .vertical
        copy.alignment = .fill
        copy.spacing = 7
        return copy
    }

    private func makePairButton() -> UIButton {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Connect"
        configuration.image = UIImage(
            systemName: "number",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )
        configuration.imagePadding = 9
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14,
            leading: 18,
            bottom: 14,
            trailing: 18
        )
        configuration.baseBackgroundColor = TTYBuildTheme.uiContent
        configuration.baseForegroundColor = TTYBuildTheme.uiCanvas
        TTYBuildTheme.applyTextFont(to: &configuration, emphasized: true)

        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "ttybuild.onboarding.pair"
        button.addAction(UIAction { [weak self] _ in self?.onEnterCode?() }, for: .touchUpInside)
        return button
    }

    private func makeLabel(
        _ text: String,
        color: UIColor,
        alignment: NSTextAlignment,
        emphasized: Bool = false
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = emphasized
            ? TTYBuildTheme.uiEmphasizedTextFont
            : TTYBuildTheme.uiTextFont
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.textAlignment = alignment
        label.numberOfLines = 0
        return label
    }
}

/// A deliberately oversized, code-drawn hero. The terminal window is the computer,
/// while the white phone in front makes the remote-control relationship clear.
@MainActor
private final class RemoteTerminalHeroView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard rect.width > 0, rect.height > 0, let context = UIGraphicsGetCurrentContext() else {
            return
        }

        let haloRect = CGRect(
            x: rect.midX - rect.width * 0.46,
            y: rect.midY - rect.width * 0.46,
            width: rect.width * 0.92,
            height: rect.width * 0.92
        )
        context.setFillColor(UIColor.white.withAlphaComponent(0.035).cgColor)
        context.fillEllipse(in: haloRect)

        let route = UIBezierPath()
        route.move(to: CGPoint(x: rect.width * 0.17, y: rect.height * 0.78))
        route.addCurve(
            to: CGPoint(x: rect.width * 0.83, y: rect.height * 0.28),
            controlPoint1: CGPoint(x: rect.width * 0.35, y: rect.height * 0.96),
            controlPoint2: CGPoint(x: rect.width * 0.68, y: rect.height * 0.08)
        )
        context.saveGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [3, 8])
        context.addPath(route.cgPath)
        context.strokePath()
        context.restoreGState()

        let desktopRect = CGRect(
            x: rect.width * 0.04,
            y: rect.height * 0.12,
            width: rect.width * 0.78,
            height: rect.height * 0.60
        )
        let desktopPath = UIBezierPath(roundedRect: desktopRect, cornerRadius: 28)
        context.setFillColor(TTYBuildTheme.uiSurface.cgColor)
        context.addPath(desktopPath.cgPath)
        context.fillPath()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(1)
        context.addPath(desktopPath.cgPath)
        context.strokePath()

        let toolbarY = desktopRect.minY + 42
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: desktopRect.minX, y: toolbarY))
        context.addLine(to: CGPoint(x: desktopRect.maxX, y: toolbarY))
        context.strokePath()

        for index in 0..<3 {
            let dot = CGRect(
                x: desktopRect.minX + 18 + CGFloat(index) * 14,
                y: desktopRect.minY + 17,
                width: 6,
                height: 6
            )
            context.setFillColor(UIColor.white.withAlphaComponent(index == 0 ? 0.8 : 0.3).cgColor)
            context.fillEllipse(in: dot)
        }

        let promptOrigin = CGPoint(x: desktopRect.minX + 24, y: toolbarY + 29)
        drawPill(
            in: context,
            rect: CGRect(x: promptOrigin.x, y: promptOrigin.y, width: 11, height: 11),
            color: TTYBuildTheme.uiContent
        )
        drawPill(
            in: context,
            rect: CGRect(
                x: promptOrigin.x + 21,
                y: promptOrigin.y + 2,
                width: desktopRect.width * 0.38,
                height: 7
            ),
            color: UIColor.white.withAlphaComponent(0.86)
        )
        drawPill(
            in: context,
            rect: CGRect(
                x: promptOrigin.x + 21,
                y: promptOrigin.y + 26,
                width: desktopRect.width * 0.55,
                height: 7
            ),
            color: UIColor.white.withAlphaComponent(0.34)
        )
        drawPill(
            in: context,
            rect: CGRect(
                x: promptOrigin.x + 21,
                y: promptOrigin.y + 50,
                width: desktopRect.width * 0.43,
                height: 7
            ),
            color: UIColor.white.withAlphaComponent(0.22)
        )

        let cursor = CGRect(
            x: promptOrigin.x + 21,
            y: desktopRect.maxY - 43,
            width: 10,
            height: 18
        )
        context.setFillColor(TTYBuildTheme.uiContent.cgColor)
        context.fill(cursor)

        let phoneRect = CGRect(
            x: rect.width * 0.66,
            y: rect.height * 0.43,
            width: rect.width * 0.27,
            height: rect.height * 0.49
        )
        let phonePath = UIBezierPath(roundedRect: phoneRect, cornerRadius: 25)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 14),
            blur: 28,
            color: UIColor.black.cgColor
        )
        context.setFillColor(TTYBuildTheme.uiContent.cgColor)
        context.addPath(phonePath.cgPath)
        context.fillPath()
        context.restoreGState()

        let phoneScreen = phoneRect.insetBy(dx: 5, dy: 5)
        let screenPath = UIBezierPath(roundedRect: phoneScreen, cornerRadius: 21)
        context.setFillColor(TTYBuildTheme.uiCanvas.cgColor)
        context.addPath(screenPath.cgPath)
        context.fillPath()

        drawPill(
            in: context,
            rect: CGRect(x: phoneRect.midX - 13, y: phoneRect.minY + 12, width: 26, height: 5),
            color: UIColor.white.withAlphaComponent(0.62)
        )
        drawPill(
            in: context,
            rect: CGRect(x: phoneRect.minX + 18, y: phoneRect.midY - 12, width: 9, height: 9),
            color: TTYBuildTheme.uiContent
        )
        drawPill(
            in: context,
            rect: CGRect(
                x: phoneRect.minX + 34,
                y: phoneRect.midY - 10,
                width: phoneRect.width * 0.36,
                height: 6
            ),
            color: TTYBuildTheme.uiContent
        )
        drawPill(
            in: context,
            rect: CGRect(
                x: phoneRect.minX + 34,
                y: phoneRect.midY + 12,
                width: phoneRect.width * 0.28,
                height: 6
            ),
            color: UIColor.white.withAlphaComponent(0.36)
        )

        let secureBadge = CGRect(
            x: desktopRect.minX - 6,
            y: desktopRect.maxY - 30,
            width: 58,
            height: 58
        )
        let securePath = UIBezierPath(roundedRect: secureBadge, cornerRadius: 20)
        context.setFillColor(TTYBuildTheme.uiContent.cgColor)
        context.addPath(securePath.cgPath)
        context.fillPath()

        if let lock = UIImage(
            systemName: "lock.shield.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        )?.withTintColor(TTYBuildTheme.uiCanvas, renderingMode: .alwaysOriginal) {
            lock.draw(
                in: CGRect(
                    x: secureBadge.midX - 14,
                    y: secureBadge.midY - 14,
                    width: 28,
                    height: 28
                )
            )
        }
    }

    private func drawPill(in context: CGContext, rect: CGRect, color: UIColor) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        context.setFillColor(color.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
    }
}
