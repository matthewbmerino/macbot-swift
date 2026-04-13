import SwiftUI
import MarkdownUI

struct CanvasNodeView: View {
    let node: CanvasNode
    let isSelected: Bool
    let isEditing: Bool
    let isAIStreaming: Bool
    var isProcessingSource: Bool = false
    let isEntered3D: Bool
    let isHovered: Bool
    let scale: CGFloat
    var onTextChange: (String) -> Void
    var onCommitEdit: () -> Void
    var onStartEdge: () -> Void
    var onExecute: () -> Void = {}

    @State private var localText: String = ""
    @State private var isExpanded: Bool = false
    @State private var contentOverflows: Bool = false
    @FocusState private var textFocused: Bool

    private let maxCollapsedHeight: CGFloat = 160

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
                    .font(.callout)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .scrollContentBackground(.hidden)
                    .focused($textFocused)
                    .frame(minHeight: 40, maxHeight: 240)
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
                        .font(.callout)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .italic()
                } else {
                    ZStack(alignment: .bottom) {
                        nodeTextContent
                            .frame(maxHeight: isExpanded ? nil : maxCollapsedHeight, alignment: .top)
                            .clipped()
                            .background(
                                GeometryReader { geo in
                                    Color.clear.onAppear {
                                        contentOverflows = geo.size.height >= maxCollapsedHeight
                                    }
                                    .onChange(of: node.text) {
                                        contentOverflows = geo.size.height >= maxCollapsedHeight
                                    }
                                }
                            )

                        if contentOverflows && !isExpanded {
                            LinearGradient(
                                colors: [.clear, MacbotDS.Colors.bg.opacity(0.9)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 32)
                        }
                    }

                    if contentOverflows {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: MacbotDS.Space.xs) {
                                Text(isExpanded ? "Show less" : "Show more")
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(MacbotDS.Colors.textSec)
                        }
                        .buttonStyle(.plain)
                    }
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
        .overlay(alignment: .topTrailing) {
            // Execute button — appears on hover
            if isHovered && !isEditing && !isAIStreaming && !node.text.isEmpty {
                Button(action: onExecute) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MacbotDS.Colors.accent)
                        .frame(width: 24, height: 24)
                        .background(MacbotDS.Colors.accent.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Execute (Cmd+Return)")
                .offset(x: -MacbotDS.Space.sm, y: MacbotDS.Space.sm)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            // Connector port — appears on hover, drag to create edge
            if isHovered && !isEditing {
                ConnectorPort(onStartEdge: onStartEdge)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isAIStreaming {
                ProcessingBadge(label: "Processing...")
                    .padding(.trailing, MacbotDS.Space.sm)
                    .padding(.top, MacbotDS.Space.sm)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isProcessingSource {
                ProcessingBadge(label: "Thinking...")
                    .padding(.trailing, MacbotDS.Space.sm)
                    .padding(.bottom, MacbotDS.Space.sm)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var nodeTextContent: some View {
        if isAIStreaming {
            Text(node.text)
                .font(.callout)
                .foregroundStyle(MacbotDS.Colors.textPri)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Markdown(node.text)
                .markdownTextStyle {
                    FontSize(13)
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
                .font(.system(size: 11))
                .foregroundStyle(origin.role == .user ? MacbotDS.Colors.textSec : MacbotDS.Colors.accent)
            Text(origin.role == .user ? "You" : "macbot")
                .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11))
                .foregroundStyle(Color(hue: 0.35, saturation: 0.6, brightness: 0.85))
            Text(origin.action.capitalized)
                .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11, weight: .semibold))
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
        .fill.secondary
    }
}

// MARK: - Processing Badge

private struct ProcessingBadge: View {
    let label: String
    @State private var dotOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: MacbotDS.Space.xs) {
            Circle()
                .fill(MacbotDS.Colors.accent)
                .frame(width: 5, height: 5)
                .opacity(dotOpacity)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: dotOpacity)
                .onAppear { dotOpacity = 0.3 }
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(MacbotDS.Colors.accent)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(MacbotDS.Colors.accent.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Connector Port

struct ConnectorPort: View {
    var onStartEdge: () -> Void
    @State private var portHovered = false

    var body: some View {
        HStack {
            Spacer()
            Circle()
                .fill(portHovered ? MacbotDS.Colors.accent : MacbotDS.Colors.accent.opacity(0.5))
                .frame(width: portHovered ? 12 : 8, height: portHovered ? 12 : 8)
                .shadow(color: MacbotDS.Colors.accent.opacity(0.3), radius: portHovered ? 4 : 0)
                .onHover { portHovered = $0 }
                .onTapGesture { onStartEdge() }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in onStartEdge() }
                )
                .offset(x: 4)
                .animation(.easeOut(duration: 0.12), value: portHovered)
        }
    }
}
