import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI

struct CanvasView: View {
    @Bindable var viewModel: CanvasViewModel
    var loadMessages: ((String) -> [ChatMessageRecord])?
    var orchestrator: Orchestrator?
    @State private var aiPromptText = ""
    @State private var showAIBar = false

    /// Center of the canvas viewport in view coordinates (for keyboard zoom).
    private var viewCenter: CGPoint {
        CGPoint(x: viewModel.viewSize.width / 2, y: viewModel.viewSize.height / 2)
    }

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
                    if viewModel.showCanvasChat {
                        canvasChatBar
                    } else if showAIBar && !viewModel.selectedIds.isEmpty {
                        canvasAIBar
                    }
                    canvasToolbar
                }
            }
            .clipped()
            .background(MacbotDS.Colors.bg)
            .onKeyPress(.delete) {
                guard viewModel.editingNodeId == nil else { return .ignored }
                withAnimation(Motion.snappy) { viewModel.deleteSelected() }
                return .handled
            }
            // Spacebar pan mode is handled by CanvasScrollHandler's NSEvent monitor
            // so it doesn't steal space key from text editors
            // Zoom shortcuts
            .onKeyPress(characters: CharacterSet(charactersIn: "=+")) { _ in
                withAnimation(Motion.snappy) {
                    viewModel.zoom(by: 1.25, anchor: viewCenter)
                }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "-")) { _ in
                withAnimation(Motion.snappy) {
                    viewModel.zoom(by: 0.8, anchor: viewCenter)
                }
                return .handled
            }
            // Backspace also deletes
            .onKeyPress(.init("\u{08}")) {
                guard viewModel.editingNodeId == nil else { return .ignored }
                withAnimation(Motion.snappy) { viewModel.deleteSelected() }
                return .handled
            }
            // Cmd shortcuts
            .onKeyPress(characters: CharacterSet(charactersIn: "01agcvxdz")) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                switch press.characters {
                case "0":
                    withAnimation(Motion.smooth) {
                        viewModel.offset = .zero
                        viewModel.lastCommittedOffset = .zero
                        viewModel.scale = 1.0
                        viewModel.lastCommittedScale = 1.0
                    }
                    return .handled
                case "1":
                    withAnimation(Motion.smooth) { viewModel.zoomToFit() }
                    return .handled
                case "a":
                    viewModel.selectAll()
                    return .handled
                case "g":
                    withAnimation(Motion.snappy) { viewModel.groupFromSelection() }
                    return .handled
                case "c":
                    viewModel.copySelected()
                    return .handled
                case "v":
                    withAnimation(Motion.snappy) { viewModel.paste() }
                    return .handled
                case "x":
                    viewModel.cutSelected()
                    return .handled
                case "d":
                    withAnimation(Motion.snappy) { viewModel.duplicateSelected() }
                    return .handled
                case "z":
                    if press.modifiers.contains(.shift) {
                        withAnimation(Motion.snappy) { viewModel.redo() }
                    } else {
                        withAnimation(Motion.snappy) { viewModel.undo() }
                    }
                    return .handled
                default:
                    return .ignored
                }
            }
            // Cmd+Return = execute selected nodes
            .onKeyPress(.return) {
                guard NSEvent.modifierFlags.contains(.command),
                      viewModel.editingNodeId == nil,
                      !viewModel.selectedIds.isEmpty else { return .ignored }
                executeSelectedNodes()
                return .handled
            }
            // Quick add shortcuts (only when not editing)
            .onKeyPress(characters: CharacterSet(charactersIn: "ntre/")) { press in
                guard viewModel.editingNodeId == nil else { return .ignored }
                guard !press.modifiers.contains(.command) else { return .ignored }
                switch press.characters {
                case "n": quickAdd(color: .note); return .handled
                case "t": quickAdd(color: .task); return .handled
                case "r": quickAdd(color: .reference); return .handled
                case "e":
                    viewModel.edgeModeActive.toggle()
                    return .handled
                case "/":
                    withAnimation(Motion.snappy) { showAIBar = true }
                    return .handled
                default: return .ignored
                }
            }
            // Escape cascade: 3D → edge mode → AI bar → chat → deselect
            .onKeyPress(.escape) {
                if viewModel.entered3DNodeId != nil {
                    viewModel.exit3DNode()
                } else if viewModel.edgeModeActive {
                    viewModel.edgeModeActive = false
                    viewModel.pendingEdgeFromId = nil
                } else if showAIBar {
                    withAnimation(Motion.snappy) { showAIBar = false }
                } else if viewModel.showCanvasChat {
                    withAnimation(Motion.snappy) {
                        viewModel.showCanvasChat = false
                        viewModel.chatAnchorNodeId = nil
                    }
                } else {
                    viewModel.clearSelection()
                }
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

    // MARK: - Background Grid + Scroll Handler

    private var canvasBackground: some View {
        GeometryReader { geo in
            ZStack {
                // Grid
                Canvas { ctx, size in
                    drawGrid(ctx: ctx, size: size)
                }

                // NSView layer for scroll wheel zoom + trackpad pan with momentum
                CanvasScrollHandler(
                    onPan: { dx, dy in
                        viewModel.handleTrackpadPan(deltaX: dx, deltaY: dy)
                    },
                    onZoom: { factor, anchor in
                        viewModel.zoom(by: factor, anchor: anchor)
                    },
                    onSpacebarChanged: { down in
                        viewModel.isSpacebarDown = down
                    },
                    onMouseMoved: { point in
                        if viewModel.pendingEdgeFromId != nil {
                            viewModel.pendingEdgeEnd = point
                        }
                    }
                )
            }
            .contentShape(Rectangle())
            // Spacebar + drag for pan (Figma pattern)
            .gesture(spacebarPanGesture)
            .onTapGesture(count: 2) { location in
                withAnimation(Motion.snappy) {
                    let canvasPoint = viewModel.viewToCanvas(location)
                    viewModel.addNode(at: canvasPoint)
                }
            }
            .onTapGesture(count: 1) { _ in
                viewModel.pendingEdgeFromId = nil
                viewModel.exit3DNode()
                viewModel.clearSelection()
                showAIBar = false
            }
            .onAppear { viewModel.viewSize = geo.size }
            .onChange(of: geo.size) { _, newSize in viewModel.viewSize = newSize }
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 40 * viewModel.scale
        guard spacing > 4 else { return }

        let ox = viewModel.offset.width.truncatingRemainder(dividingBy: spacing)
        let oy = viewModel.offset.height.truncatingRemainder(dividingBy: spacing)
        let dotRadius: CGFloat = max(1.5, 1.5 * viewModel.scale)
        let color = Color(nsColor: .separatorColor).opacity(0.55)

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

    /// Spacebar + drag for manual panning (Figma-style).
    private var spacebarPanGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard viewModel.isSpacebarDown else { return }
                viewModel.offset = CGSize(
                    width: viewModel.lastCommittedOffset.width + value.translation.width,
                    height: viewModel.lastCommittedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                viewModel.lastCommittedOffset = viewModel.offset
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

    private func edgeSwiftUIColor(_ edge: CanvasEdge) -> Color {
        let c = edge.color.color
        if edge.color == .neutral {
            return MacbotDS.Colors.textTer.opacity(0.55)
        }
        return Color(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
    }

    private var edgesLayer: some View {
        Canvas { ctx, _ in
            for edge in viewModel.edges {
                guard let from = viewModel.nodes.first(where: { $0.id == edge.fromId }),
                      let to = viewModel.nodes.first(where: { $0.id == edge.toId }) else { continue }

                let p1 = viewModel.canvasToView(from.position)
                let p2 = viewModel.canvasToView(to.position)
                let lineWidth = edge.weight.lineWidth * viewModel.scale

                // Curved path
                var path = Path()
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                let cp1 = CGPoint(x: mid.x, y: p1.y)
                let cp2 = CGPoint(x: mid.x, y: p2.y)
                path.move(to: p1)
                path.addCurve(to: p2, control1: cp1, control2: cp2)

                let c = edge.color.color
                let resolvedColor: Color
                if edge.color == .neutral {
                    resolvedColor = Color(nsColor: .tertiaryLabelColor).opacity(0.55)
                } else {
                    resolvedColor = Color(hue: c.hue, saturation: c.saturation, brightness: c.brightness)
                }

                let strokeStyle = StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: edge.style.dashPattern.map { $0 * viewModel.scale }
                )
                ctx.stroke(path, with: .color(resolvedColor), style: strokeStyle)

                // Arrowheads based on direction
                let arrowLen: CGFloat = (6 + edge.weight.lineWidth * 2) * viewModel.scale

                if edge.direction == .forward || edge.direction == .both {
                    let angle = atan2(p2.y - cp2.y, p2.x - cp2.x)
                    drawArrowhead(ctx: ctx, at: p2, angle: angle, length: arrowLen,
                                  color: resolvedColor, lineWidth: lineWidth)
                }

                if edge.direction == .backward || edge.direction == .both {
                    let angle = atan2(p1.y - cp1.y, p1.x - cp1.x)
                    drawArrowhead(ctx: ctx, at: p1, angle: angle, length: arrowLen,
                                  color: resolvedColor, lineWidth: lineWidth)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawArrowhead(
        ctx: GraphicsContext, at point: CGPoint, angle: CGFloat,
        length: CGFloat, color: Color, lineWidth: CGFloat
    ) {
        var arrow = Path()
        arrow.move(to: point)
        arrow.addLine(to: CGPoint(
            x: point.x - length * cos(angle - .pi / 6),
            y: point.y - length * sin(angle - .pi / 6)
        ))
        arrow.move(to: point)
        arrow.addLine(to: CGPoint(
            x: point.x - length * cos(angle + .pi / 6),
            y: point.y - length * sin(angle + .pi / 6)
        ))
        ctx.stroke(arrow, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    // MARK: - Edge Labels & Interaction

    private var edgeLabelsLayer: some View {
        ForEach(viewModel.edges) { edge in
            if let from = viewModel.nodes.first(where: { $0.id == edge.fromId }),
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
                    edgeLabelView(edge: edge)
                        .position(midpoint)
                        .scaleEffect(viewModel.scale)
                        .onTapGesture(count: 2) {
                            viewModel.editingEdgeId = edge.id
                            viewModel.editingEdgeLabel = edge.label ?? ""
                        }
                        .contextMenu { edgeContextMenu(edge: edge) }
                }
            }
        }
    }

    private func edgeLabelView(edge: CanvasEdge) -> some View {
        let hasLabel = edge.label != nil && !edge.label!.isEmpty
        let displayColor = edgeSwiftUIColor(edge)

        return HStack(spacing: 3) {
            // Direction indicator
            if edge.direction == .both {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 7))
            }

            if hasLabel {
                Text(edge.label!)
                    .font(.system(size: 9, weight: .medium))
            }

            // Style indicator dot for non-solid lines without a label
            if !hasLabel {
                Circle()
                    .fill(displayColor)
                    .frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(displayColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(MacbotDS.Mat.float)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func edgeContextMenu(edge: CanvasEdge) -> some View {
        // Relationship presets
        Menu("Relationship") {
            ForEach(EdgePreset.allCases, id: \.self) { preset in
                Button(preset.label) { viewModel.applyEdgePreset(id: edge.id, preset: preset) }
            }
        }

        Divider()

        // Line style
        Menu("Line Style") {
            ForEach(CanvasEdge.EdgeStyle.allCases, id: \.self) { style in
                Button {
                    viewModel.updateEdgeStyle(id: edge.id, style: style)
                } label: {
                    HStack {
                        Text(style.rawValue.capitalized)
                        if edge.style == style { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        // Color
        Menu("Color") {
            ForEach(CanvasEdge.EdgeColor.allCases, id: \.self) { color in
                Button {
                    viewModel.updateEdgeColor(id: edge.id, color: color)
                } label: {
                    HStack {
                        Text(color.rawValue.capitalized)
                        if edge.color == color { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        // Direction
        Menu("Direction") {
            ForEach(CanvasEdge.EdgeDirection.allCases, id: \.self) { dir in
                Button {
                    viewModel.updateEdgeDirection(id: edge.id, direction: dir)
                } label: {
                    let symbol: String = switch dir {
                    case .forward:  "arrow.right"
                    case .backward: "arrow.left"
                    case .both:     "arrow.left.arrow.right"
                    case .none:     "minus"
                    }
                    HStack {
                        Label(dir.rawValue.capitalized, systemImage: symbol)
                        if edge.direction == dir { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        // Weight
        Menu("Weight") {
            ForEach(CanvasEdge.EdgeWeight.allCases, id: \.self) { w in
                Button {
                    viewModel.updateEdgeWeight(id: edge.id, weight: w)
                } label: {
                    HStack {
                        Text(w.rawValue.capitalized)
                        if edge.weight == w { Image(systemName: "checkmark") }
                    }
                }
            }
        }

        Divider()

        Button("Edit Label") {
            viewModel.editingEdgeId = edge.id
            viewModel.editingEdgeLabel = edge.label ?? ""
        }

        Button("Remove Label") {
            viewModel.updateEdgeLabel(id: edge.id, label: "")
        }

        Divider()

        Button("Delete Connection", role: .destructive) {
            viewModel.deleteEdge(id: edge.id)
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
                isAIStreaming: viewModel.aiStreamingNodeId == node.id
                    || viewModel.activeCouncilNodeIds.contains(node.id),
                isEntered3D: viewModel.entered3DNodeId == node.id,
                scale: viewModel.scale,
                onTextChange: { viewModel.updateText(id: node.id, text: $0) },
                onCommitEdit: { viewModel.editingNodeId = nil },
                onStartEdge: { viewModel.pendingEdgeFromId = node.id }
            )
            .position(viewModel.canvasToView(node.position))
            .scaleEffect(viewModel.scale * (viewModel.draggingNodeId == node.id ? 1.03 : 1.0))
            .shadow(
                color: viewModel.draggingNodeId == node.id ? .black.opacity(0.18) : .clear,
                radius: 20, y: 8
            )
            .animation(Motion.snappy, value: viewModel.draggingNodeId == node.id)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .scale(scale: 0.9).combined(with: .opacity)
            ))
            .onTapGesture(count: 2) {
                viewModel.select(node.id)
                if node.sceneData != nil {
                    // Enter 3D interaction mode
                    viewModel.enter3DNode(id: node.id)
                } else {
                    viewModel.editingNodeId = node.id
                }
            }
            // Unified drag gesture — disambiguates click vs drag by distance
            .gesture(nodeDragGesture(node: node))
            .contextMenu {
                nodeContextMenu(node: node)
            }
        }
    }

    @ViewBuilder
    private func nodeContextMenu(node: CanvasNode) -> some View {
        // Execute — the primary AI action
        Button("Execute") {
            viewModel.select(node.id)
            executeSelectedNodes()
        }

        Button("Edit") {
            viewModel.select(node.id)
            viewModel.editingNodeId = node.id
        }

        Button("Chat from here") {
            viewModel.startChat(from: node.id)
        }

        // 3D viewport actions
        if node.sceneData != nil {
            if node.displayMode == .card {
                Button("Detach 3D Viewport") {
                    viewModel.detach3DViewport(nodeId: node.id)
                }
            } else if node.displayMode == .viewport3D {
                Button("Re-attach to Card") {
                    viewModel.reattachToCard(nodeId: node.id)
                }
            }
            Button(viewModel.entered3DNodeId == node.id ? "Exit 3D" : "Interact with 3D") {
                if viewModel.entered3DNodeId == node.id {
                    viewModel.exit3DNode()
                } else {
                    viewModel.enter3DNode(id: node.id)
                }
            }
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

        // Agent Council
        Menu("Agent Council") {
            Button("All Agents") {
                invokeCouncil(agents: AgentCategory.allCases.filter { $0 != .vision })
            }
            Button("General + Coder + Reasoner") {
                invokeCouncil(agents: [.general, .coder, .reasoner])
            }
            Button("General + Reasoner") {
                invokeCouncil(agents: [.general, .reasoner])
            }
            Button("Coder + Reasoner") {
                invokeCouncil(agents: [.coder, .reasoner])
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

    private func executeSelectedNodes() {
        guard let orchestrator else { return }
        viewModel.executeNodes(orchestrator: orchestrator)
    }

    private func invokeCouncil(agents: [AgentCategory]) {
        guard let orchestrator else { return }
        let prompt = "Analyze these notes and provide your unique perspective, expertise, and recommendations:"
        viewModel.invokeCouncil(agents: agents, prompt: prompt, orchestrator: orchestrator)
    }

    private func nodeDragGesture(node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Don't move node when inside 3D interaction mode
                guard viewModel.entered3DNodeId != node.id else { return }
                let dist = hypot(value.translation.width, value.translation.height)
                if dist > 4 {
                    viewModel.draggingNodeId = node.id
                    let newCanvas = viewModel.viewToCanvas(value.location)
                    viewModel.moveNode(id: node.id, to: newCanvas)
                }
            }
            .onEnded { value in
                let dist = hypot(value.translation.width, value.translation.height)
                if dist <= 4 {
                    // This was a click, not a drag
                    if viewModel.pendingEdgeFromId != nil {
                        // Complete the pending edge to this node
                        viewModel.commitEdge(toId: node.id)
                    } else if viewModel.edgeModeActive {
                        // Edge mode: start a new edge from this node
                        viewModel.pendingEdgeFromId = node.id
                    } else {
                        // Normal selection
                        let exclusive = !NSEvent.modifierFlags.contains(.command)
                            && !NSEvent.modifierFlags.contains(.shift)
                        viewModel.select(node.id, exclusive: exclusive)
                    }
                } else {
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
                viewModel.draggingNodeId = nil
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

    /// Cancel button positioned at the midpoint of the edge between
    /// source nodes and the streaming AI node.
    private var aiProcessingOverlay: some View {
        Group {
            if let streamingId = viewModel.aiStreamingNodeId,
               let streamingNode = viewModel.nodes.first(where: { $0.id == streamingId }),
               let sourceEdge = viewModel.edges.first(where: { $0.toId == streamingId }),
               let sourceNode = viewModel.nodes.first(where: { $0.id == sourceEdge.fromId }) {

                let p1 = viewModel.canvasToView(sourceNode.position)
                let p2 = viewModel.canvasToView(streamingNode.position)
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

                Button(action: { viewModel.cancelAI() }) {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: "stop.circle.fill")
                            .font(.caption)
                            .symbolRenderingMode(.hierarchical)
                        Text("Stop")
                            .font(MacbotDS.Typo.detail)
                    }
                    .foregroundStyle(MacbotDS.Colors.warning)
                    .padding(.horizontal, MacbotDS.Space.md)
                    .padding(.vertical, MacbotDS.Space.sm)
                    .background(MacbotDS.Mat.chrome)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(MacbotDS.Colors.warning.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .position(mid)
                .transition(.scale.combined(with: .opacity))
            }
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

    // MARK: - Canvas Chat Bar

    private var canvasChatBar: some View {
        VStack(spacing: MacbotDS.Space.xs) {
            // Thread indicator
            if let anchorId = viewModel.chatAnchorNodeId,
               let anchor = viewModel.nodes.first(where: { $0.id == anchorId }) {
                HStack(spacing: MacbotDS.Space.xs) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 9))
                    Text("Replying to: \(anchor.text.prefix(40))\(anchor.text.count > 40 ? "..." : "")")
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Spacer()
                    Button(action: {
                        withAnimation(Motion.snappy) {
                            viewModel.showCanvasChat = false
                            viewModel.chatAnchorNodeId = nil
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(MacbotDS.Colors.textTer)
                .padding(.horizontal, MacbotDS.Space.md)
            }

            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.accent)

                TextField("Continue the conversation...", text: $viewModel.chatInputText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .onSubmit { sendCanvasChat() }

                if viewModel.isProcessingAI {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button(action: sendCanvasChat) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(
                                viewModel.chatInputText.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? MacbotDS.Colors.textTer.opacity(0.3)
                                    : MacbotDS.Colors.accent
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.chatInputText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)
        }
        .frame(maxWidth: 460)
        .background(MacbotDS.Mat.chrome)
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous)
                .stroke(MacbotDS.Colors.accent.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func sendCanvasChat() {
        guard let orchestrator else { return }
        viewModel.sendChatMessage(orchestrator: orchestrator)
    }

    // MARK: - Toolbar

    private var canvasToolbar: some View {
        VStack(spacing: MacbotDS.Space.sm) {
            // Contextual selection bar — appears when nodes are selected
            if !viewModel.selectedIds.isEmpty {
                contextualSelectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Primary toolbar
            primaryToolbar
        }
        .padding(.bottom, MacbotDS.Space.md)
    }

    private var primaryToolbar: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            canvasPickerButton

            Divider().frame(height: 18)

            // Quick Add — split button with type presets
            quickAddButton

            // Edge mode toggle
            toolbarToggle("point.forward.to.point.capsulepath.fill",
                          help: "Edge Mode (E)",
                          isActive: viewModel.edgeModeActive) {
                viewModel.edgeModeActive.toggle()
            }

            Divider().frame(height: 18)

            // Execute — zero-prompt AI, just do what the note says
            toolbarToggle("bolt.fill", help: "Execute (Cmd+Return)",
                          isActive: false) {
                executeSelectedNodes()
            }
            .disabled(viewModel.selectedIds.isEmpty || viewModel.isProcessingAI)

            toolbarButton("sparkles", help: "Ask AI (/)") {
                withAnimation(Motion.snappy) { showAIBar.toggle() }
            }
            .disabled(viewModel.selectedIds.isEmpty)

            toolbarButton("bubble.left.and.bubble.right", help: "Chat Browser") {
                withAnimation(Motion.snappy) { viewModel.showChatBrowser.toggle() }
            }

            Divider().frame(height: 18)

            // Zoom controls
            toolbarButton("minus.magnifyingglass", help: "Zoom Out (-)") {
                withAnimation(Motion.snappy) { viewModel.zoom(by: 0.8, anchor: viewCenter) }
            }

            Button(action: {
                withAnimation(Motion.smooth) {
                    viewModel.offset = .zero
                    viewModel.lastCommittedOffset = .zero
                    viewModel.scale = 1.0
                    viewModel.lastCommittedScale = 1.0
                }
            }) {
                Text("\(Int(viewModel.scale * 100))%")
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .monospacedDigit()
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .help("Reset zoom (Cmd+0)")

            toolbarButton("plus.magnifyingglass", help: "Zoom In (+)") {
                withAnimation(Motion.snappy) { viewModel.zoom(by: 1.25, anchor: viewCenter) }
            }

            toolbarButton("arrow.up.left.and.arrow.down.right", help: "Zoom to Fit (Cmd+1)") {
                withAnimation(Motion.smooth) { viewModel.zoomToFit() }
            }
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(MacbotDS.Mat.chrome)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(MacbotDS.Colors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    // MARK: - Contextual Selection Bar

    private var contextualSelectionBar: some View {
        HStack(spacing: MacbotDS.Space.xs) {
            // Color picker — direct color circles
            ForEach(CanvasNode.NodeColor.allCases, id: \.self) { color in
                Button(action: { viewModel.setColor(color) }) {
                    Circle()
                        .fill(color == .note
                              ? Color.secondary
                              : Color(hue: color.hue, saturation: 0.5, brightness: 0.85))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(color.rawValue.capitalized)
            }

            Divider().frame(height: 16)

            // Width presets
            Menu {
                Button("Small (160)") { viewModel.resizeSelected(width: 160) }
                Button("Medium (220)") { viewModel.resizeSelected(width: 220) }
                Button("Large (300)") { viewModel.resizeSelected(width: 300) }
                Button("Wide (400)") { viewModel.resizeSelected(width: 400) }
            } label: {
                Image(systemName: "arrow.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .help("Resize")

            // Alignment (only when 2+ selected)
            if viewModel.selectedIds.count >= 2 {
                Divider().frame(height: 16)

                Menu {
                    Section("Align") {
                        Button("Left") { viewModel.alignSelected(.left) }
                        Button("Center") { viewModel.alignSelected(.centerH) }
                        Button("Right") { viewModel.alignSelected(.right) }
                        Divider()
                        Button("Top") { viewModel.alignSelected(.top) }
                        Button("Middle") { viewModel.alignSelected(.centerV) }
                        Button("Bottom") { viewModel.alignSelected(.bottom) }
                    }
                    if viewModel.selectedIds.count >= 3 {
                        Section("Distribute") {
                            Button("Horizontally") { viewModel.distributeSelected(axis: .horizontal) }
                            Button("Vertically") { viewModel.distributeSelected(axis: .vertical) }
                        }
                    }
                } label: {
                    Image(systemName: "align.horizontal.left")
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textSec)
                        .frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .help("Align & Distribute")
            }

            Divider().frame(height: 16)

            // Group / Ungroup
            if viewModel.selectedIds.count >= 2 {
                toolbarSmallButton("rectangle.3.group", help: "Group (Cmd+G)") {
                    withAnimation(Motion.snappy) { viewModel.groupFromSelection() }
                }
            }

            // Duplicate
            toolbarSmallButton("plus.square.on.square", help: "Duplicate (Cmd+D)") {
                withAnimation(Motion.snappy) { viewModel.duplicateSelected() }
            }

            // Undo / Redo
            toolbarSmallButton("arrow.uturn.backward", help: "Undo (Cmd+Z)") {
                withAnimation(Motion.snappy) { viewModel.undo() }
            }
            .disabled(!viewModel.canUndo)

            toolbarSmallButton("arrow.uturn.forward", help: "Redo (Cmd+Shift+Z)") {
                withAnimation(Motion.snappy) { viewModel.redo() }
            }
            .disabled(!viewModel.canRedo)

            Divider().frame(height: 16)

            // Delete
            toolbarSmallButton("trash", help: "Delete") {
                withAnimation(Motion.snappy) { viewModel.deleteSelected() }
            }

            // Selection count
            Text("\(viewModel.selectedIds.count) selected")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(MacbotDS.Colors.textTer)
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, 6)
        .background(MacbotDS.Mat.chrome)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(MacbotDS.Colors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }

    // MARK: - Quick Add

    private var quickAddButton: some View {
        Menu {
            Button("Note") { quickAdd(color: .note) }
                .keyboardShortcut("n", modifiers: [])
            Button("Idea") { quickAdd(color: .idea) }
            Button("Task") { quickAdd(color: .task) }
            Button("Reference") { quickAdd(color: .reference) }
        } label: {
            Image(systemName: "plus")
                .font(.subheadline)
                .foregroundStyle(MacbotDS.Colors.textSec)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("Add Node")
    }

    private func quickAdd(color: CanvasNode.NodeColor) {
        let center = viewModel.viewToCanvas(viewCenter)
        let jittered = CGPoint(
            x: center.x + CGFloat.random(in: -30...30),
            y: center.y + CGFloat.random(in: -30...30)
        )
        withAnimation(Motion.snappy) {
            viewModel.addNode(at: jittered, color: color)
        }
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

    private func toolbarSmallButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.textSec)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toolbarToggle(_ icon: String, help: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(isActive ? MacbotDS.Colors.accent : MacbotDS.Colors.textSec)
                .frame(width: 28, height: 28)
                .background(isActive ? MacbotDS.Colors.accent.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

    // MARK: - Viewport 3D Mode (free-floating)

    private var viewport3DBody: some View {
        VStack(spacing: 0) {
            // Thin toolbar strip — drag handle
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

            // 3D viewport
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

    // MARK: - Card Mode (existing)

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
                    // Plain text during streaming — avoid expensive Markdown parsing
                    Text(node.text)
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Rendered Markdown for display
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

            // 3D Scene (interactive SceneKit viewport)
            if let sceneData = node.sceneData {
                SceneKitNodeView(sceneDescription: sceneData, isInteractive: isEntered3D)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
            }

            // Images (from AI generation)
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
        if node.color == .note {
            return MacbotDS.Colors.textSec
        }
        return Color(hue: node.color.hue, saturation: 0.5, brightness: 0.85)
    }

    private var nodeBackground: some ShapeStyle {
        MacbotDS.Mat.chrome
    }
}
