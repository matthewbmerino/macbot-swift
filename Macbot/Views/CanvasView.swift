import SwiftUI
import UniformTypeIdentifiers

struct CanvasView: View {
    @Bindable var viewModel: CanvasViewModel
    var loadMessages: ((String) -> [ChatMessageRecord])?
    var orchestrator: Orchestrator?
    @State private var aiPromptText = ""
    @State private var showAIBar = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                canvasBackground
                groupsLayer
                edgesLayer
                edgeLabelsLayer
                pendingEdgeLayer
                nodesLayer

                // AI streaming indicator
                if viewModel.isProcessingAI {
                    aiProcessingOverlay
                }

                // Floating UI
                VStack(spacing: MacbotDS.Space.sm) {
                    Spacer()
                    if showAIBar && !viewModel.selectedIds.isEmpty {
                        canvasAIBar
                    }
                    canvasToolbar
                }
            }
            .clipped()
            .background(MacbotDS.Colors.bg)
            .onKeyPress(.delete) {
                viewModel.deleteSelected()
                return .handled
            }
            .dropDestination(for: ChatDragItem.self) { items, location in
                handleChatDrop(items: items, at: location)
                return true
            } isTargeted: { targeted in
                viewModel.dropTargeted = targeted
            }
            .overlay {
                if viewModel.dropTargeted {
                    dropOverlay
                }
            }

            if viewModel.showChatBrowser {
                Divider()
                chatBrowserPanel
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Drop Handling

    private func handleChatDrop(items: [ChatDragItem], at location: CGPoint) {
        for item in items {
            let canvasPoint = viewModel.viewToCanvas(location)
            let msgs = loadMessages?(item.chatId) ?? []
            if msgs.isEmpty { continue }

            viewModel.addChatThread(
                messages: msgs,
                chatId: item.chatId,
                chatTitle: item.chatTitle,
                centerAt: canvasPoint
            )
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous)
            .stroke(MacbotDS.Colors.accent.opacity(0.5), lineWidth: 1.5)
            .background(.ultraThinMaterial.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous))
            .overlay {
                VStack(spacing: MacbotDS.Space.sm) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 28, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                    Text("Drop chat to add as thread")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(MacbotDS.Colors.accent.opacity(0.8))
            }
            .padding(MacbotDS.Space.xs)
            .allowsHitTesting(false)
    }

    // MARK: - Background Grid + Gestures

    private var canvasBackground: some View {
        GeometryReader { _ in
            Canvas { ctx, size in
                drawGrid(ctx: ctx, size: size)
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(zoomGesture)
            .onTapGesture(count: 2) { location in
                let canvasPoint = viewModel.viewToCanvas(location)
                viewModel.addNode(at: canvasPoint)
            }
            .onTapGesture(count: 1) { _ in
                viewModel.clearSelection()
                showAIBar = false
            }
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 40 * viewModel.scale
        guard spacing > 4 else { return }

        let ox = viewModel.offset.width.truncatingRemainder(dividingBy: spacing)
        let oy = viewModel.offset.height.truncatingRemainder(dividingBy: spacing)
        let dotRadius: CGFloat = max(1, viewModel.scale)
        let color = Color(nsColor: .separatorColor).opacity(0.35)

        var x = ox
        while x < size.width {
            var y = oy
            while y < size.height {
                ctx.fill(
                    Path(ellipseIn: CGRect(
                        x: x - dotRadius / 2, y: y - dotRadius / 2,
                        width: dotRadius, height: dotRadius
                    )),
                    with: .color(color)
                )
                y += spacing
            }
            x += spacing
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                viewModel.offset = CGSize(
                    width: viewModel.lastCommittedOffset.width + value.translation.width,
                    height: viewModel.lastCommittedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                viewModel.lastCommittedOffset = viewModel.offset
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                viewModel.scale = min(max(value.magnification, 0.25), 4.0)
            }
    }

    // MARK: - Groups Layer

    private var groupsLayer: some View {
        ForEach(viewModel.groups) { group in
            CanvasGroupFrame(
                group: group,
                scale: viewModel.scale,
                onRename: { viewModel.renameGroup(id: group.id, title: $0) },
                onDelete: { viewModel.deleteGroup(id: group.id) }
            )
            .position(viewModel.canvasToView(CGPoint(
                x: group.position.x + group.size.width / 2,
                y: group.position.y + group.size.height / 2
            )))
            .scaleEffect(viewModel.scale)
        }
    }

    // MARK: - Edges

    private var edgesLayer: some View {
        Canvas { ctx, _ in
            for edge in viewModel.edges {
                guard let from = viewModel.nodes.first(where: { $0.id == edge.fromId }),
                      let to = viewModel.nodes.first(where: { $0.id == edge.toId }) else { continue }

                let p1 = viewModel.canvasToView(from.position)
                let p2 = viewModel.canvasToView(to.position)

                var path = Path()
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                let cp1 = CGPoint(x: mid.x, y: p1.y)
                let cp2 = CGPoint(x: mid.x, y: p2.y)
                path.move(to: p1)
                path.addCurve(to: p2, control1: cp1, control2: cp2)

                ctx.stroke(
                    path,
                    with: .color(MacbotDS.Colors.textTer.opacity(0.5)),
                    lineWidth: 1.5 * viewModel.scale
                )

                // Arrowhead
                let angle = atan2(p2.y - cp2.y, p2.x - cp2.x)
                let arrowLen: CGFloat = 8 * viewModel.scale
                var arrow = Path()
                arrow.move(to: p2)
                arrow.addLine(to: CGPoint(
                    x: p2.x - arrowLen * cos(angle - .pi / 6),
                    y: p2.y - arrowLen * sin(angle - .pi / 6)
                ))
                arrow.move(to: p2)
                arrow.addLine(to: CGPoint(
                    x: p2.x - arrowLen * cos(angle + .pi / 6),
                    y: p2.y - arrowLen * sin(angle + .pi / 6)
                ))
                ctx.stroke(
                    arrow,
                    with: .color(MacbotDS.Colors.textTer.opacity(0.5)),
                    lineWidth: 1.5 * viewModel.scale
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Edge Labels

    private var edgeLabelsLayer: some View {
        ForEach(viewModel.edges) { edge in
            if let label = edge.label,
               let from = viewModel.nodes.first(where: { $0.id == edge.fromId }),
               let to = viewModel.nodes.first(where: { $0.id == edge.toId }) {
                let p1 = viewModel.canvasToView(from.position)
                let p2 = viewModel.canvasToView(to.position)
                let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

                if viewModel.editingEdgeId == edge.id {
                    EdgeLabelEditor(
                        text: $viewModel.editingEdgeLabel,
                        onCommit: { viewModel.updateEdgeLabel(id: edge.id, label: viewModel.editingEdgeLabel) }
                    )
                    .position(midpoint)
                    .scaleEffect(viewModel.scale)
                } else {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MacbotDS.Mat.float)
                        .clipShape(Capsule())
                        .position(midpoint)
                        .scaleEffect(viewModel.scale)
                        .onTapGesture(count: 2) {
                            viewModel.editingEdgeId = edge.id
                            viewModel.editingEdgeLabel = label
                        }
                        .contextMenu {
                            ForEach(["supports", "contradicts", "leads to", "expands", "example of"], id: \.self) { preset in
                                Button(preset) { viewModel.updateEdgeLabel(id: edge.id, label: preset) }
                            }
                            Divider()
                            Button("Remove Label") { viewModel.updateEdgeLabel(id: edge.id, label: "") }
                        }
                }
            }
        }
    }

    private var pendingEdgeLayer: some View {
        Canvas { ctx, _ in
            guard let fromId = viewModel.pendingEdgeFromId,
                  let from = viewModel.nodes.first(where: { $0.id == fromId }) else { return }

            let p1 = viewModel.canvasToView(from.position)
            let p2 = viewModel.pendingEdgeEnd

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)

            ctx.stroke(
                path,
                with: .color(MacbotDS.Colors.accent.opacity(0.6)),
                style: StrokeStyle(lineWidth: 1.5 * viewModel.scale, dash: [6, 4])
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Nodes

    private var nodesLayer: some View {
        ForEach(viewModel.nodes) { node in
            CanvasNodeView(
                node: node,
                isSelected: viewModel.selectedIds.contains(node.id),
                isEditing: viewModel.editingNodeId == node.id,
                isAIStreaming: viewModel.aiStreamingNodeId == node.id,
                scale: viewModel.scale,
                onTextChange: { viewModel.updateText(id: node.id, text: $0) },
                onCommitEdit: { viewModel.editingNodeId = nil },
                onStartEdge: { viewModel.pendingEdgeFromId = node.id }
            )
            .position(viewModel.canvasToView(node.position))
            .scaleEffect(viewModel.scale)
            .onTapGesture(count: 2) {
                viewModel.select(node.id)
                viewModel.editingNodeId = node.id
            }
            .onTapGesture(count: 1) {
                let exclusive = !NSEvent.modifierFlags.contains(.shift)
                viewModel.select(node.id, exclusive: exclusive)
            }
            .gesture(nodeDragGesture(node: node))
            .contextMenu {
                nodeContextMenu(node: node)
            }
        }
    }

    @ViewBuilder
    private func nodeContextMenu(node: CanvasNode) -> some View {
        Button("Edit") {
            viewModel.select(node.id)
            viewModel.editingNodeId = node.id
        }

        Divider()

        Menu("Ask macbot") {
            Button("Summarize") {
                viewModel.select(node.id)
                invokeAI(action: "summarize", prompt: "Summarize the following concisely, capturing the key points:")
            }
            Button("Expand") {
                viewModel.select(node.id)
                invokeAI(action: "expand", prompt: "Elaborate on this with deeper research, related concepts, and supporting evidence:")
            }
            Button("Find Connections") {
                invokeAI(action: "connect", prompt: "Analyze these notes and identify non-obvious connections, patterns, and relationships between them:")
            }
            Button("Critique") {
                invokeAI(action: "critique", prompt: "Play devil's advocate. Find weaknesses, gaps, and counterarguments to these ideas:")
            }
            Button("Extract Tasks") {
                invokeAI(action: "tasks", prompt: "Extract concrete action items and next steps from these notes. Be specific and actionable:")
            }
        }

        Divider()

        Button("Cycle Color") { viewModel.cycleColor(id: node.id) }

        if viewModel.selectedIds.count >= 2 {
            Button("Group Selected") { viewModel.groupFromSelection() }
        }

        if node.groupId != nil {
            Button("Remove from Group") { viewModel.ungroupSelected() }
        }

        Divider()

        Button("Delete", role: .destructive) {
            viewModel.select(node.id)
            viewModel.deleteSelected()
        }
    }

    private func invokeAI(action: String, prompt: String) {
        guard let orchestrator else { return }
        viewModel.invokeAI(action: action, prompt: prompt, orchestrator: orchestrator)
    }

    private func nodeDragGesture(node: CanvasNode) -> some Gesture {
        DragGesture()
            .onChanged { value in
                viewModel.draggingNodeId = node.id
                let newCanvas = viewModel.viewToCanvas(value.location)
                viewModel.moveNode(id: node.id, to: newCanvas)
            }
            .onEnded { value in
                viewModel.draggingNodeId = nil
                viewModel.commitMove()
                if viewModel.pendingEdgeFromId != nil {
                    let dropPoint = viewModel.viewToCanvas(value.location)
                    if let target = hitTest(dropPoint, excluding: node.id) {
                        viewModel.commitEdge(toId: target.id)
                    } else {
                        viewModel.pendingEdgeFromId = nil
                    }
                }
            }
    }

    private func hitTest(_ canvasPoint: CGPoint, excluding: UUID? = nil) -> CanvasNode? {
        viewModel.nodes.first { node in
            guard node.id != excluding else { return false }
            let dx = canvasPoint.x - node.position.x
            let dy = canvasPoint.y - node.position.y
            return abs(dx) < node.width / 2 && abs(dy) < 40
        }
    }

    // MARK: - AI Processing Overlay

    private var aiProcessingOverlay: some View {
        VStack {
            HStack(spacing: MacbotDS.Space.sm) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("macbot is thinking...")
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(MacbotDS.Colors.textSec)
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)
            .background(MacbotDS.Mat.chrome)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            .padding(.top, MacbotDS.Space.md)
            Spacer()
        }
    }

    // MARK: - AI Prompt Bar

    private var canvasAIBar: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(MacbotDS.Colors.accent)

            TextField("Ask macbot about selected nodes...", text: $aiPromptText)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(MacbotDS.Colors.textPri)
                .onSubmit {
                    guard !aiPromptText.isEmpty else { return }
                    invokeAI(action: "question", prompt: aiPromptText)
                    aiPromptText = ""
                    showAIBar = false
                }

            Button(action: {
                guard !aiPromptText.isEmpty else { return }
                invokeAI(action: "question", prompt: aiPromptText)
                aiPromptText = ""
                showAIBar = false
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(aiPromptText.isEmpty ? MacbotDS.Colors.textTer.opacity(0.3) : MacbotDS.Colors.accent)
            }
            .buttonStyle(.plain)
            .disabled(aiPromptText.isEmpty)
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .frame(maxWidth: 420)
        .background(MacbotDS.Mat.chrome)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(MacbotDS.Colors.accent.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Toolbar

    private var canvasToolbar: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            // Canvas picker
            canvasPickerButton

            Divider().frame(height: 18)

            toolbarButton("plus", help: "Add Note") {
                let center = viewModel.viewToCanvas(CGPoint(x: 400, y: 300))
                let jittered = CGPoint(
                    x: center.x + CGFloat.random(in: -30...30),
                    y: center.y + CGFloat.random(in: -30...30)
                )
                viewModel.addNode(at: jittered)
            }

            Divider().frame(height: 18)

            toolbarButton("paintpalette", help: "Cycle Color") {
                for id in viewModel.selectedIds { viewModel.cycleColor(id: id) }
            }
            .disabled(viewModel.selectedIds.isEmpty)

            toolbarButton("rectangle.3.group", help: "Group Selected") {
                viewModel.groupFromSelection()
            }
            .disabled(viewModel.selectedIds.count < 2)

            toolbarButton("trash", help: "Delete Selected") {
                viewModel.deleteSelected()
            }
            .disabled(viewModel.selectedIds.isEmpty)

            Divider().frame(height: 18)

            toolbarButton("sparkles", help: "Ask AI") {
                withAnimation(Motion.snappy) { showAIBar.toggle() }
            }
            .disabled(viewModel.selectedIds.isEmpty)

            toolbarButton("bubble.left.and.bubble.right", help: "Chat Browser") {
                withAnimation(Motion.snappy) { viewModel.showChatBrowser.toggle() }
            }

            Divider().frame(height: 18)

            toolbarButton("arrow.up.left.and.arrow.down.right", help: "Reset View") {
                withAnimation(Motion.smooth) {
                    viewModel.offset = .zero
                    viewModel.lastCommittedOffset = .zero
                    viewModel.scale = 1.0
                }
            }

            Text("\(Int(viewModel.scale * 100))%")
                .font(MacbotDS.Typo.detail)
                .foregroundStyle(MacbotDS.Colors.textSec)
                .monospacedDigit()
                .frame(width: 40)
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(MacbotDS.Mat.chrome)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(MacbotDS.Colors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .padding(.bottom, MacbotDS.Space.md)
    }

    // MARK: - Canvas Picker

    private var canvasPickerButton: some View {
        Menu {
            ForEach(viewModel.canvasList) { canvas in
                Button(action: { viewModel.switchCanvas(canvas.id) }) {
                    HStack {
                        Text(canvas.title)
                        if canvas.id == viewModel.currentCanvasId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("New Canvas") { viewModel.createCanvas() }
        } label: {
            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.caption2)
                let title = viewModel.canvasList.first(where: { $0.id == viewModel.currentCanvasId })?.title ?? "Canvas"
                Text(title)
                    .font(MacbotDS.Typo.detail)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(MacbotDS.Colors.textSec)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 120)
    }

    // MARK: - Chat Browser Panel

    private var chatBrowserPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.accent)
                Text("Chat History")
                    .font(MacbotDS.Typo.heading)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                Spacer()
                Button(action: {
                    withAnimation(Motion.snappy) { viewModel.showChatBrowser = false }
                }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.md)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.availableChats) { chat in
                        chatBrowserRow(chat)
                    }
                }
                .padding(.vertical, MacbotDS.Space.xs)
            }
        }
        .background(MacbotDS.Mat.chrome)
    }

    private func chatBrowserRow(_ chat: ChatRecord) -> some View {
        let isExpanded = viewModel.browserExpandedChatId == chat.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .lineLimit(1)
                    Text(chat.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }

                Spacer()

                Button(action: {
                    let msgs = loadMessages?(chat.id) ?? []
                    let center = viewModel.viewToCanvas(CGPoint(x: 300, y: 200))
                    let jittered = CGPoint(x: center.x + CGFloat.random(in: -40...40), y: center.y)
                    viewModel.addChatThread(messages: msgs, chatId: chat.id, chatTitle: chat.title, centerAt: jittered)
                }) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.accent)
                        .padding(4)
                        .background(MacbotDS.Colors.accent.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Add full thread to canvas")
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Motion.snappy) {
                    if isExpanded {
                        viewModel.browserExpandedChatId = nil
                        viewModel.browserMessages = []
                    } else {
                        viewModel.browserExpandedChatId = chat.id
                        viewModel.browserMessages = loadMessages?(chat.id) ?? []
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        viewModel.browserMessages.filter { $0.role == "user" || $0.role == "assistant" },
                        id: \.id
                    ) { msg in
                        chatMessageRow(msg, chatId: chat.id, chatTitle: chat.title)
                    }
                }
                .padding(.leading, MacbotDS.Space.lg)
                .padding(.trailing, MacbotDS.Space.sm)
                .padding(.bottom, MacbotDS.Space.sm)
            }
        }
    }

    private func chatMessageRow(_ msg: ChatMessageRecord, chatId: String, chatTitle: String) -> some View {
        let role = MessageRole(rawValue: msg.role) ?? .user
        let isUser = role == .user

        return Button(action: {
            let center = viewModel.viewToCanvas(CGPoint(x: 300, y: 300))
            let jittered = CGPoint(
                x: center.x + CGFloat.random(in: -60...60),
                y: center.y + CGFloat.random(in: -60...60)
            )
            viewModel.addChatNode(
                at: jittered,
                content: msg.content.count > 300 ? String(msg.content.prefix(297)) + "..." : msg.content,
                chatId: chatId,
                chatTitle: chatTitle,
                role: role,
                agentCategory: msg.agentCategory.flatMap { AgentCategory(rawValue: $0) },
                timestamp: msg.createdAt
            )
        }) {
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: isUser ? "person.circle" : "cube.transparent")
                    .font(.caption2)
                    .foregroundStyle(isUser ? MacbotDS.Colors.textSec : MacbotDS.Colors.accent)
                Text(msg.content)
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus.circle")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
            }
            .padding(.horizontal, MacbotDS.Space.sm)
            .padding(.vertical, MacbotDS.Space.xs + 2)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Add to canvas")
    }

    private func toolbarButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(MacbotDS.Colors.textSec)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Edge Label Editor

private struct EdgeLabelEditor: View {
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

// MARK: - Group Frame

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

            // Title
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

// MARK: - Individual Node Card

struct CanvasNodeView: View {
    let node: CanvasNode
    let isSelected: Bool
    let isEditing: Bool
    let isAIStreaming: Bool
    let scale: CGFloat
    var onTextChange: (String) -> Void
    var onCommitEdit: () -> Void
    var onStartEdge: () -> Void

    @State private var localText: String = ""
    @FocusState private var textFocused: Bool

    var body: some View {
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
                } else {
                    Text(node.text)
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Source footer
            switch node.source {
            case .chat(let origin):
                chatFooter(origin)
            case .ai(let origin):
                aiFooter(origin)
            case .manual:
                EmptyView()
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

    // MARK: - Header variants

    @ViewBuilder
    private var nodeHeader: some View {
        switch node.source {
        case .chat(let origin):
            chatHeader(origin)
        case .ai(let origin):
            aiHeader(origin)
        case .manual:
            manualHeader
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

            Button(action: onStartEdge) {
                Image(systemName: "point.forward.to.point.capsulepath.fill")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
            }
            .buttonStyle(.plain)
            .help("Connect to another node")
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

            Button(action: onStartEdge) {
                Image(systemName: "point.forward.to.point.capsulepath.fill")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
            }
            .buttonStyle(.plain)
            .help("Connect to another node")
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

            Button(action: onStartEdge) {
                Image(systemName: "point.forward.to.point.capsulepath.fill")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
            }
            .buttonStyle(.plain)
            .help("Connect to another node")
        }
    }

    // MARK: - Footers

    private func chatFooter(_ origin: NodeSource.ChatOrigin) -> some View {
        HStack(spacing: MacbotDS.Space.xs) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 8))
            Text(origin.chatTitle)
                .lineLimit(1)
            Text("·")
            Text(origin.timestamp, style: .relative)
        }
        .font(.system(size: 9))
        .foregroundStyle(MacbotDS.Colors.textTer)
    }

    private func aiFooter(_ origin: NodeSource.AIOrigin) -> some View {
        HStack(spacing: MacbotDS.Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 8))
            Text("Generated")
            Text("·")
            Text(origin.timestamp, style: .relative)
        }
        .font(.system(size: 9))
        .foregroundStyle(Color(hue: 0.35, saturation: 0.4, brightness: 0.7))
    }

    // MARK: - Styling

    private var nodeAccent: Color {
        if node.color == .note {
            return MacbotDS.Colors.textSec
        }
        return Color(hue: node.color.hue, saturation: 0.5, brightness: 0.85)
    }

    private var nodeBackground: some ShapeStyle {
        MacbotDS.Mat.chrome
    }
}
