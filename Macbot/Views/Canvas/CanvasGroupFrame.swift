import SwiftUI

struct CanvasGroupFrame: View {
    let group: CanvasGroup
    let scale: CGFloat
    var onRename: (String) -> Void
    var onDelete: () -> Void

    @State private var isEditingTitle = false
    @State private var titleText = ""

    private var groupColor: Color {
        if group.color == .note {
            return MacbotDS.Colors.textTer
        }
        return Color(hue: group.color.hue, saturation: 0.3, brightness: 0.8)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous)
                .fill(groupColor.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous)
                        .stroke(groupColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                )
                .frame(width: group.size.width, height: group.size.height)

            if isEditingTitle {
                TextField("Group name", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(groupColor)
                    .frame(width: 120)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .background(MacbotDS.Mat.float)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm))
                    .padding(MacbotDS.Space.sm)
                    .onSubmit {
                        onRename(titleText)
                        isEditingTitle = false
                    }
                    .onKeyPress(.escape) {
                        isEditingTitle = false
                        return .handled
                    }
            } else {
                Text(group.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(groupColor)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .padding(MacbotDS.Space.sm)
                    .onTapGesture(count: 2) {
                        titleText = group.title
                        isEditingTitle = true
                    }
            }
        }
        .contextMenu {
            Button("Rename") {
                titleText = group.title
                isEditingTitle = true
            }
            Button("Delete Group", role: .destructive) { onDelete() }
        }
    }
}
