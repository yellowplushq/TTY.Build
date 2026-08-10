//
//  AEOTPTextField.swift
//  AEOTPTextField
//
//  Created by Abdelrhman Eliwa on 10/12/20.
//  Copyright © 2020 Abdelrhman Eliwa. All rights reserved.
//  Adapted for Swift 6 by TTYBuild.
//

import UIKit

/// A single native text field backed by one visual label per OTP digit.
/// Source: https://github.com/AbdelrhmanKamalEliwa/AEOTPTextField
@MainActor
final class AEOTPTextField: UITextField {
    var otpDefaultCharacter = ""
    var otpBackgroundColor = UIColor(red: 0.949, green: 0.949, blue: 0.949, alpha: 1)
    var otpFilledBackgroundColor = UIColor(red: 0.949, green: 0.949, blue: 0.949, alpha: 1)
    var otpCornerRadius: CGFloat = 10
    var otpDefaultBorderColor = UIColor.clear
    var otpFilledBorderColor = UIColor.darkGray
    var otpDefaultBorderWidth: CGFloat = 0
    var otpFilledBorderWidth: CGFloat = 1
    var otpTextColor = UIColor.black
    var otpFont = UIFont.systemFont(ofSize: 14)
    weak var otpDelegate: AEOTPTextFieldDelegate?

    private let implementation = AEOTPTextFieldImplementation()
    private var isConfigured = false
    private var digitLabels: [UILabel] = []
    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(focusInput))
        return recognizer
    }()

    func configure(with slotCount: Int = 6) {
        guard !isConfigured, slotCount > 0 else { return }
        isConfigured = true
        configureTextField()

        let labelsStackView = createLabelsStackView(with: slotCount)
        addSubview(labelsStackView)
        addGestureRecognizer(tapRecognizer)
        NSLayoutConstraint.activate([
            labelsStackView.topAnchor.constraint(equalTo: topAnchor),
            labelsStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelsStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelsStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func clearOTP() {
        text = nil
        updateDigitLabels()
    }

    private func configureTextField() {
        tintColor = .clear
        textColor = .clear
        keyboardType = .numberPad
        textContentType = .oneTimeCode
        autocorrectionType = .no
        spellCheckingType = .no
        borderStyle = .none
        addTarget(self, action: #selector(textDidChange), for: .editingChanged)
        delegate = implementation
        implementation.implementationDelegate = self
    }

    private func createLabelsStackView(with count: Int) -> UIStackView {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.distribution = .fillEqually
        stackView.semanticContentAttribute = semanticContentAttribute
        stackView.spacing = 8

        for _ in 0..<count {
            let label = UILabel()
            label.backgroundColor = otpBackgroundColor
            label.layer.cornerRadius = otpCornerRadius
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textAlignment = .center
            label.textColor = otpTextColor
            label.font = otpFont
            label.isUserInteractionEnabled = true
            label.layer.masksToBounds = true
            label.text = otpDefaultCharacter
            label.layer.borderWidth = otpDefaultBorderWidth
            label.layer.borderColor = otpDefaultBorderColor.cgColor
            stackView.addArrangedSubview(label)
            digitLabels.append(label)
        }
        return stackView
    }

    @objc private func focusInput() {
        becomeFirstResponder()
    }

    @objc private func textDidChange() {
        updateDigitLabels()
        if text?.count == digitLabels.count, let text {
            otpDelegate?.didUserFinishEnter(the: text)
        }
    }

    private func updateDigitLabels() {
        let characters = Array(text ?? "")
        for (index, label) in digitLabels.enumerated() {
            if characters.indices.contains(index) {
                label.text = isSecureTextEntry ? "✱" : String(characters[index])
                label.layer.borderWidth = otpFilledBorderWidth
                label.layer.borderColor = otpFilledBorderColor.cgColor
                label.backgroundColor = otpFilledBackgroundColor
            } else {
                label.text = otpDefaultCharacter
                label.layer.borderWidth = otpDefaultBorderWidth
                label.layer.borderColor = otpDefaultBorderColor.cgColor
                label.backgroundColor = otpBackgroundColor
            }
        }
    }
}

extension AEOTPTextField: AEOTPTextFieldImplementationProtocol {
    var digitalLabelsCount: Int { digitLabels.count }
}
