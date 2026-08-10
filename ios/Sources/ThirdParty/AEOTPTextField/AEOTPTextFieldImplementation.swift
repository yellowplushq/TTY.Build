//
//  AEOTPTextFieldImplementation.swift
//  ViberTemplate
//
//  Created by Abdelrhman Eliwa on 09/05/2021.
//  Adapted for Swift 6 and strict numeric input by TTYBuild.
//

import UIKit

@MainActor
final class AEOTPTextFieldImplementation: NSObject, UITextFieldDelegate {
    weak var implementationDelegate: AEOTPTextFieldImplementationProtocol?

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        let asciiDigits = CharacterSet(charactersIn: "0123456789")
        guard string.isEmpty || string.unicodeScalars.allSatisfy(asciiDigits.contains),
              let current = textField.text,
              let swiftRange = Range(range, in: current)
        else { return false }

        let replacement = current.replacingCharacters(in: swiftRange, with: string)
        return replacement.count <= (implementationDelegate?.digitalLabelsCount ?? 0)
    }
}
