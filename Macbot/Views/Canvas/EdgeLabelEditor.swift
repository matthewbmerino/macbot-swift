import SwiftUI

struct EdgeLabelEditor: View {
    @Binding var text: String
    var onCommit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Label...", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(MacbotDS.Colors.textPri)
            .frame(width: 100)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(MacbotDS.Mat.chrome)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(MacbotDS.Colors.accent.opacity(0.4), lineWidth: 0.5))
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { onCommit() }
            .onKeyPress(.escape) {
                onCommit()
                return .handled
            }
    }
}
