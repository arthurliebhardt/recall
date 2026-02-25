import SwiftUI

struct ChatInputView: View {
    @Binding var text: String
    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask something about this transcription...", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit {
                    if canSend && !NSEvent.modifierFlags.contains(.shift) {
                        onSend()
                    }
                }
                .disabled(isGenerating)

            if isGenerating {
                Button(action: onCancel) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send message (Enter)")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
    }
}
