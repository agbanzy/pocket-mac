import SwiftUI
import PocketMacKit

/// A compact keyboard bar. Tapping "Type" focuses a hidden `UITextField` whose keystrokes stream to
/// the Mac as `unicodeText` frames (printable text) or `keyDown`/`keyUp` for Return / Delete / Tab.
struct KeyboardBarView: View {
    var onFrame: (Frame) -> Void
    @State private var isActive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(isActive ? "Keyboard active — type to send" : "Send keystrokes to your Mac")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(isActive ? "Hide" : "Type") { isActive.toggle() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            // The hidden field itself — 1pt, effectively invisible, holds first responder.
            HiddenKeyboardField(isActive: $isActive, onFrame: onFrame)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A 1x1 `UITextField` that never keeps its content: every edit is translated to an input frame and
/// rejected (`return false`), so a persistent sentinel space keeps backspace firing even when empty.
struct HiddenKeyboardField: UIViewRepresentable {
    @Binding var isActive: Bool
    var onFrame: (Frame) -> Void

    // macOS virtual key codes.
    static let keyReturn: UInt16 = 36
    static let keyTab: UInt16 = 48
    static let keyDelete: UInt16 = 51

    func makeCoordinator() -> Coordinator { Coordinator(isActive: $isActive, onFrame: onFrame) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .asciiCapable
        field.text = " " // sentinel so a backspace on empty still yields a delete callback
        field.tintColor = .clear
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onFrame = onFrame
        if isActive, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isActive, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var isActive: Bool
        var onFrame: (Frame) -> Void

        init(isActive: Binding<Bool>, onFrame: @escaping (Frame) -> Void) {
            self._isActive = isActive
            self.onFrame = onFrame
        }

        func textField(_ textField: UITextField,
                       shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            if string.isEmpty {
                sendKey(HiddenKeyboardField.keyDelete)
            } else if string == "\n" {
                sendKey(HiddenKeyboardField.keyReturn)
            } else if string == "\t" {
                sendKey(HiddenKeyboardField.keyTab)
            } else {
                onFrame(.input(.unicodeText(string)))
            }
            return false // never mutate the hidden field's content
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            sendKey(HiddenKeyboardField.keyReturn)
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if isActive { isActive = false }
        }

        private func sendKey(_ keyCode: UInt16) {
            onFrame(.input(.keyDown(keyCode: keyCode, modifiers: [])))
            onFrame(.input(.keyUp(keyCode: keyCode, modifiers: [])))
        }
    }
}
