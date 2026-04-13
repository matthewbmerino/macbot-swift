import SwiftUI
import MarkdownUI

struct CanvasNodeView: View {
    let node: CanvasNode
    let isSelected: Bool
    let isEditing: Bool
    let isAIStreaming: Bool
    let isEntered3D: Bool
    let scale: CGFloat
    var onTextChange: (String) -> Void
    var onCommitEdit: () -> Void
    var onStartEdge: () -> Void

    @State private var localText: String = ""
    @FocusState private var textFocused: Bool

    var body: some View {
        if node.displayMode == .viewport3D {
            viewport3DBody
        } else {
            cardBody
        }
    }

    // MARK: - Viewport 3D Mode

    private var viewport3DBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9))
                    .foregroundStyle(MacbotDS.Colors.textTer)
                Spacer()
                if isEntered3D {
                    Text("Orbit · Esc to exit")
                        .font(.system(size: 9))
                        .foregroundStyle(MacbotDS.Colors.accent.opacity(0.7))
                } else {
                    Text("Double-click to interact")
                        .font(.system(size: 9))
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }
                Spacer()
                Button(action: onStartEdge) {
                    Image(systemName: "point.forward.to.point.capsulepath.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, MacbotDS.Space.sm)
            .padding(.vertical, 4)
            .background(MacbotDS.Colors.bg.opacity(0.6))

            if let sceneData = node.sceneData {
                SceneKitNodeView(sceneDescription: sceneData, isInteractive: isEntered3D)
                    .frame(height: node.viewportHeight ?? 250)
            }
        }
        .frame(width: node.width)
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                .stroke(
                    isEntered3D ? MacbotDS.Colors.accent :
                        isSelected ? MacbotDS.Colors.textSec :
                        MacbotDS.Colors.separator.opacity(0.3),
                    lineWidth: isEntered3D ? 2 : isSelected ? 1.5 : 0.5
                )
        )
        .shadow(
            color: isEntered3D ? MacbotDS.Colors.accent.opacity(0.15) : .black.opacity(0.12),
            radius: isEntered3D ? 16 : 8,
            y: 4
        )
    }

    // MARK: - Card Mode

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
            nodeHeader

            if isEditing {
                TextEditor(text: $localText)
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .scrollContentBackground(.hidden)
                    .focused($textFocused)
                    .frame(minHeight: 40, maxHeight: 200)
                    .onAppear {
                        localText = node.text
                        textFocused = true
                    }
                    .onChange(of: localText) { _, newValue in
                        onTextChange(newValue)
                    }
                    .onKeyPress(.escape) {
                        onCommitEdit()
                        return .handled
                    }
            } else {
                if node.text.isEmpty {
                    Text("Double-click to edit...")
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .italic()
                } else if isAIStreaming {
                    Text(node.text)
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Markdown(node.text)
                        .markdownTextStyle {
                            FontSize(11)
                            ForegroundColor(MacbotDS.Colors.textPri)
                        }
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            configuration.label
                                .padding(MacbotDS.Space.sm)
                                .background(.fill.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                        }
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let sceneData = node.sceneData {
                SceneKitNodeView(sceneDescription: sceneData, isInteractive: isEntered3D)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
            }

            if let images = node.images, !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: MacbotDS.Space.xs) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                            if let nsImage = NSImage(data: data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                            }
                        }
                    }
                }
            }

            switch node.source {
            case .chat(let origin): chatFooter(origin)
            case .ai(let origin): aiFooter(origin)
            case .manual: EmptyView()
            }
        }
        .padding(MacbotDS.Space.md)
        .frame(width: node.width)
        .background(nodeBackground)
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(
            color: isSelected ? nodeAccent.opacity(0.2) : .black.opacity(0.08),
            radius: isSelected ? 12 : 6,
            y: isSelected ? 2 : 3
        )
        .opacity(isAIStreaming ? 0.9 : 1.0)
        .animation(isAIStreaming ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isAIStreaming)
    }

    private var borderColor: Color {
        if isAIStreaming { return MacbotDS.Colors.accent }
        if isSelected { return nodeAccent }
        return MacbotDS.Colors.separator
    }

    private var borderWidth: CGFloat {
        if isAIStreaming { return 2.0 }
        if isSelected { return 1.5 }
        return 0.5
    }

    // MARK: - Headers

    @ViewBuilder
    private var nodeHeader: some View {
        switch node.source {
        case .chat(let origin): chatHeader(origin)
        case .ai(let origin): aiHeader(origin)
        case .manual: manualHeader
        }
    }

    private func chatHeader(_ origin: NodeSource.ChatOrigin) -> some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: origin.role == .user ? "person.circle.fill" : "cube.transparent.fill")
                .font(.caption)
                .foregroundStyle(origin.role == .user ? MacbotDS.Colors.textSec : MacbotDS.Colors.accent)
            Text(origin.role == .user ? "You" : "macbot")
                .font(MacbotDS.Typo.detail)
                .foregroundStyle(MacbotDS.Colors.textPri)
            if let agent = origin.agentCategory {
                Text(agent.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
            Spacer()
            connectButton
        }
    }

    private func aiHeader(_ origin: NodeSource.AIOrigin) -> some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(Color(hue: 0.35, saturation: 0.6, brightness: 0.85))
            Text(origin.action.capitalized)
                .font(MacbotDS.Typo.detail)
                .foregroundStyle(MacbotDS.Colors.textPri)
            Spacer()
            connectButton
        }
    }

    private var manualHeader: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Circle()
                .fill(nodeAccent)
                .frame(width: 8, height: 8)
            Text(node.color.rawValue.capitalized)
                .font(MacbotDS.Typo.detail)
                .foregroundStyle(MacbotDS.Colors.textTer)
            Spacer()
            connectButton
        }
    }

    private var connectButton: some View {
        Button(action: onStartEdge) {
            Image(systemName: "point.forward.to.point.capsulepath.fill")
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.textTer)
        }
        .buttonStyle(.plain)
        .help("Connect to another node")
    }

    // MARK: - Footers

    private func chatFooter(_ origin: NodeSource.ChatOrigin) -> some View {
        HStack(spacing: MacbotDS.Space.xs) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 8))
            Text(origin.chatTitle)
                .lineLimit(1)
        }
        .font(.system(size: 9))
        .foregroundStyle(MacbotDS.Colors.textTer)
    }

    private func aiFooter(_ origin: NodeSource.AIOrigin) -> some View {
        HStack(spacing: MacbotDS.Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 8))
            Text("Generated")
        }
        .font(.system(size: 9))
        .foregroundStyle(Color(hue: 0.35, saturation: 0.4, brightness: 0.7))
    }

    // MARK: - Styling

    private var nodeAccent: Color {
        node.color.accentColor
    }

    private var nodeBackground: some ShapeStyle {
        MacbotDS.Mat.chrome
    }
}
