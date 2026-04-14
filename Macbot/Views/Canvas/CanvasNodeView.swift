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
    var onWidgetExecute: () -> Void = {}
    var onWidgetEdit: () -> Void = {}
    var onWidgetRerun: () -> Void = {}
    var onWidgetExpand: () -> Void = {}
    var onEnterEdit: () -> Void = {}

    @State private var localText: String = ""
    @State private var isExpanded: Bool = false
    @State private var measuredContentHeight: CGFloat = 0
    @State private var keyMonitor: Any?
    @FocusState private var textFocused: Bool

    private var contentOverflows: Bool {
        measuredContentHeight > maxCollapsedHeight
    }

    private let maxCollapsedHeight: CGFloat = 100
    private let maxEditorHeight: CGFloat = 80

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
                VStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
                    TextEditor(text: $localText)
                        .font(.callout)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .frame(minHeight: 32, maxHeight: maxEditorHeight)
                        .onAppear {
                            localText = node.text
                            textFocused = true
                            installKeyMonitor()
                            // Always start collapsed when editing so card stays compact after commit
                            isExpanded = false
                        }
                        .onDisappear {
                            removeKeyMonitor()
                            // Reset to compact view after editing finishes
                            isExpanded = false
                            // Force re-measurement of the newly committed text
                            measuredContentHeight = 0
                        }
                        .onChange(of: localText) { _, newValue in
                            onTextChange(newValue)
                        }

                    // Subtle keyboard hint
                    HStack(spacing: 6) {
                        Text("↩ Answer  ·  ⌘↩ Expand")
                            .font(.system(size: 9))
                            .foregroundStyle(MacbotDS.Colors.textTer.opacity(0.6))
                        Spacer()
                    }
                }
            } else {
                if node.text.isEmpty {
                    Text("Click to type...")
                        .font(.callout)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .italic()
                        .contentShape(Rectangle())
                        .onTapGesture { onEnterEdit() }
                } else {
                    // Visible content: clipped to maxCollapsedHeight when it would overflow and is not expanded.
                    nodeTextContent
                        .frame(
                            maxHeight: (contentOverflows && !isExpanded) ? maxCollapsedHeight : nil,
                            alignment: .top
                        )
                        .clipped()
                        .background(
                            // Off-screen measurement view — only rendered while we
                            // don't yet have a measured height. Once measured we
                            // drop it so we're not re-parsing the Markdown twice
                            // on every body eval (pan/zoom, hover, etc.). The
                            // onChange below resets measuredContentHeight to 0
                            // when the text actually changes so we re-measure.
                            Group {
                                if measuredContentHeight == 0 {
                                    nodeTextContent
                                        .frame(width: max(0, node.width - MacbotDS.Space.md * 2), alignment: .topLeading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .background(
                                            GeometryReader { geo in
                                                Color.clear
                                                    .preference(key: ContentHeightPreferenceKey.self, value: geo.size.height)
                                            }
                                        )
                                        .hidden()
                                        .allowsHitTesting(false)
                                }
                            }
                        )
                        .onPreferenceChange(ContentHeightPreferenceKey.self) { newHeight in
                            if abs(newHeight - measuredContentHeight) > 0.5 {
                                measuredContentHeight = newHeight
                            }
                        }
                        .onChange(of: node.text) { _, _ in
                            // Force re-measurement when the text changes (AI
                            // streaming, edits). Also re-measure if width changed.
                            measuredContentHeight = 0
                        }
                        .onChange(of: node.width) { _, _ in
                            measuredContentHeight = 0
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 1) {
                            // Single click on text content of selected node = enter edit
                            if isSelected { onEnterEdit() }
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

            // Widget result footer — edit/rerun/expand buttons
            if node.widgetState == .result {
                widgetResultFooter
            } else if node.widgetState == .error {
                widgetErrorFooter
            } else {
                switch node.source {
                case .chat(let origin): chatFooter(origin)
                case .ai(let origin): aiFooter(origin)
                case .manual: EmptyView()
                }
            }

            // Inline processing footer — replaces the old overlay badges
            // that used to cover the card's text. Reserved space at the
            // bottom of the card so the content above it stays readable.
            if isAIStreaming || isProcessingSource {
                processingFooter
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
            // Single execute button on hover — hidden during any processing
            // state (either this card is being written into, or it's feeding
            // another AI op) because re-triggering is ambiguous mid-flight.
            if isHovered && !isEditing && !isAIStreaming && !isProcessingSource
                && !node.text.isEmpty && node.widgetState != .loading {
                Button(action: onExecute) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MacbotDS.Colors.accent)
                        .frame(width: 22, height: 22)
                        .background(MacbotDS.Colors.accent.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Execute (⌘↩ expand · ↩ answer in editor)")
                .padding(.trailing, MacbotDS.Space.sm)
                .padding(.top, MacbotDS.Space.sm)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .overlay(alignment: .trailing) {
            // Connector port — drag to create edge. Only appears when the
            // node is selected (not on every hover) to avoid visual noise.
            if isSelected && !isEditing {
                ConnectorPort(onStartEdge: onStartEdge)
                    .transition(.opacity)
            }
        }
    }

    /// Inline processing row shown at the bottom of the card whenever the
    /// node is participating in an in-flight AI action. Replaces the old
    /// absolute-positioned ProcessingBadge overlays which could cover the
    /// card's own text. A subtle divider + pulsing dot + short label; the
    /// card's border also pulses accent-colored (see `borderColor`).
    @ViewBuilder
    private var processingFooter: some View {
        let label: String = isAIStreaming ? "Generating" : "Thinking"
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)
            HStack(spacing: MacbotDS.Space.xs) {
                ProcessingDot()
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MacbotDS.Colors.accent)
                Spacer()
            }
            .padding(.top, MacbotDS.Space.xs)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var nodeTextContent: some View {
        if isAIStreaming {
            Text(node.text)
                .font(.callout)
                .foregroundStyle(MacbotDS.Colors.textPri)
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

    // MARK: - Key Monitor (reliable Return/Tab while editing)

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only intercept while this card is the editing target
            guard isEditing, textFocused else { return event }

            // Return key (keyCode 36)
            if event.keyCode == 36 {
                let cmdHeld = event.modifierFlags.contains(.command)
                let shiftHeld = event.modifierFlags.contains(.shift)
                if shiftHeld {
                    // Shift+Return = newline (let TextEditor handle)
                    return event
                }
                onCommitEdit()
                if cmdHeld {
                    onExecute()        // ⌘↩ = expand (knowledge graph)
                } else {
                    onWidgetExecute()  // ↩ = widget (in-place answer)
                }
                return nil  // consume
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - Widget Footers

    private var widgetResultFooter: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Button(action: onWidgetEdit) {
                HStack(spacing: 3) {
                    Image(systemName: "pencil")
                        .font(.system(size: 8))
                    Text("Edit")
                }
            }
            .buttonStyle(.plain)

            Button(action: onWidgetRerun) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8))
                    Text("Re-run")
                }
            }
            .buttonStyle(.plain)

            Button(action: onWidgetExpand) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8))
                    Text("Expand")
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(MacbotDS.Colors.accent)
    }

    private var widgetErrorFooter: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Button(action: onWidgetEdit) {
                HStack(spacing: 3) {
                    Image(systemName: "pencil")
                        .font(.system(size: 8))
                    Text("Edit")
                }
            }
            .buttonStyle(.plain)

            Button(action: onWidgetRerun) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8))
                    Text("Retry")
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(MacbotDS.Colors.danger)
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
        Color(nsColor: .windowBackgroundColor).opacity(0.95)
    }
}

// MARK: - Content Height Preference

private struct ContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Processing indicators

/// Small pulsing accent dot — used inline by the processing footer and by
/// the legacy ProcessingBadge (still exported in case other call sites use
/// it). Extracted as its own View so the state-driven animation has a
/// stable identity and doesn't restart on parent re-renders.
struct ProcessingDot: View {
    @State private var dotOpacity: Double = 1.0

    var body: some View {
        Circle()
            .fill(MacbotDS.Colors.accent)
            .frame(width: 5, height: 5)
            .opacity(dotOpacity)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: dotOpacity)
            .onAppear { dotOpacity = 0.3 }
    }
}

private struct ProcessingBadge: View {
    let label: String

    var body: some View {
        HStack(spacing: MacbotDS.Space.xs) {
            ProcessingDot()
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
