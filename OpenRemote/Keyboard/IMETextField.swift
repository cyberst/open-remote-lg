import SwiftUI
import UIKit

/// A UITextField bridge that reports text only once it is committed: while a CJK / handwriting
/// keyboard shows uncommitted "marked" text, nothing is reported, so the TV never receives half-composed input.
struct IMETextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var onCommittedChange: (String) -> Void
    var onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.delegate = context.coordinator
        f.placeholder = placeholder
        f.font = .preferredFont(forTextStyle: .title3)
        f.adjustsFontForContentSizeCategory = true
        f.clearButtonMode = .whileEditing
        f.returnKeyType = .send
        f.enablesReturnKeyAutomatically = false
        // TV search fields want plain characters, not typographic quotes/dashes.
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.autocapitalizationType = .sentences
        f.accessibilityLabel = "Text to send to the TV"
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        f.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        // Never overwrite while the user is composing marked text.
        if f.markedTextRange == nil, f.text != text { f.text = text }
        if f.placeholder != placeholder { f.placeholder = placeholder }
        if isFocused, !f.isFirstResponder, f.window != nil {
            DispatchQueue.main.async { f.becomeFirstResponder() }
        } else if !isFocused, f.isFirstResponder {
            DispatchQueue.main.async { f.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: IMETextField
        init(_ parent: IMETextField) { self.parent = parent }

        @objc func editingChanged(_ f: UITextField) {
            guard f.markedTextRange == nil else { return }
            let t = f.text ?? ""
            guard t != parent.text else { return }
            parent.text = t
            parent.onCommittedChange(t)
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            // Commit any marked text first so Return sends what is visible.
            if f.markedTextRange != nil { f.unmarkText(); editingChanged(f) }
            parent.onReturn()
            return false
        }

        func textFieldShouldClear(_ f: UITextField) -> Bool {
            if !parent.text.isEmpty {
                parent.text = ""
                parent.onCommittedChange("")
            }
            return true
        }

        func textFieldDidBeginEditing(_ f: UITextField) { if !parent.isFocused { parent.isFocused = true } }
        func textFieldDidEndEditing(_ f: UITextField) { if parent.isFocused { parent.isFocused = false } }
    }
}
