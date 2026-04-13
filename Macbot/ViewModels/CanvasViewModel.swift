import Foundation
import SwiftUI

@Observable
final class CanvasViewModel {
    // MARK: - Canvas content

    var nodes: [CanvasNode] = []
    var edges: [CanvasEdge] = []
    var groups: [CanvasGroup] = []

    // MARK: - Multi-canvas

    var canvasList: [CanvasRecord] = []
    var currentCanvasId: String?
    var showCanvasPicker = false

    // MARK: - Viewport

    var offset: CGSize = .zero
    var scale: CGFloat = 1.0
    var lastCommittedOffset: CGSize = .zero
    var lastCommittedScale: CGFloat = 1.0
    var isSpacebarDown = false
    var viewSize: CGSize = CGSize(width: 800, height: 600)

    // MARK: - Selection & interaction

    var selectedIds: Set<UUID> = []
    var editingNodeId: UUID?
    var draggingNodeId: UUID?
    var editingEdgeId: UUID?
    var editingEdgeLabel: String = ""

    /// When non-nil the user is dragging from a node port to create an edge.
    var pendingEdgeFromId: UUID?
    var pendingEdgeEnd: CGPoint = .zero

    /// Edge creation mode — click node to start, click another to connect.
    var edgeModeActive = false
    var showMinimap = false

    // MARK: - Chat browser

    var showChatBrowser = false
    var availableChats: [ChatRecord] = []
    var browserMessages: [ChatMessageRecord] = []
    var browserExpandedChatId: String?

    // MARK: - Drop state

    var dropTargeted = false

    // MARK: - AI

    var isProcessingAI = false
    var aiStreamingNodeId: UUID?
    /// Tracks active streaming node IDs during council (multiple simultaneous)
    var activeCouncilNodeIds: Set<UUID> = []
    /// The running AI task — stored so it can be cancelled.
    private var aiTask: Task<Void, Never>?

    /// Cancel any in-flight AI generation.
    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        isProcessingAI = false
        aiStreamingNodeId = nil
        activeCouncilNodeIds.removeAll()
    }

    // MARK: - Canvas Chat

    /// The node that the canvas chat is anchored to (reply thread).
    var chatAnchorNodeId: UUID?
    var chatInputText: String = ""
    var showCanvasChat: Bool = false

    // MARK: - Undo / Redo

    private var undoStack: [CanvasSnapshot] = []
    private var redoStack: [CanvasSnapshot] = []
    private static let maxUndoLevels = 40

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private struct CanvasSnapshot {
        let nodes: [CanvasNode]
        let edges: [CanvasEdge]
        let groups: [CanvasGroup]
    }

    /// Call before any mutation to push a snapshot onto the undo stack.
    private func pushUndo() {
        undoStack.append(CanvasSnapshot(nodes: nodes, edges: edges, groups: groups))
        if undoStack.count > Self.maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(CanvasSnapshot(nodes: nodes, edges: edges, groups: groups))
        nodes = snapshot.nodes
        edges = snapshot.edges
        groups = snapshot.groups
        clearSelection()
        scheduleSave()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(CanvasSnapshot(nodes: nodes, edges: edges, groups: groups))
        nodes = snapshot.nodes
        edges = snapshot.edges
        groups = snapshot.groups
        clearSelection()
        scheduleSave()
    }

    // MARK: - Clipboard

    /// Nodes + edges currently in the clipboard (in-app only).
    private var clipboard: (nodes: [CanvasNode], edges: [CanvasEdge]) = ([], [])

    func copySelected() {
        let ids = selectedIds
        clipboard.nodes = nodes.filter { ids.contains($0.id) }
        clipboard.edges = edges.filter { ids.contains($0.fromId) && ids.contains($0.toId) }
    }

    func cutSelected() {
        copySelected()
        pushUndo()
        withAnimation(Motion.snappy) { deleteSelected() }
    }

    func paste() {
        guard !clipboard.nodes.isEmpty else { return }
        pushUndo()

        // Offset pasted nodes slightly so they don't stack exactly on originals
        let pasteOffset = CGPoint(x: 30, y: 30)
        var idMap: [UUID: UUID] = [:]  // old ID → new ID

        var newNodes: [CanvasNode] = []
        for old in clipboard.nodes {
            let newId = UUID()
            idMap[old.id] = newId
            let node = CanvasNode(
                id: newId,
                position: CGPoint(x: old.position.x + pasteOffset.x, y: old.position.y + pasteOffset.y),
                text: old.text,
                width: old.width,
                color: old.color,
                source: old.source,
                groupId: nil
            )
            newNodes.append(node)
        }

        var newEdges: [CanvasEdge] = []
        for old in clipboard.edges {
            if let newFrom = idMap[old.fromId], let newTo = idMap[old.toId] {
                newEdges.append(CanvasEdge(fromId: newFrom, toId: newTo, label: old.label))
            }
        }

        nodes.append(contentsOf: newNodes)
        edges.append(contentsOf: newEdges)
        selectedIds = Set(newNodes.map(\.id))
        scheduleSave()
    }

    func duplicateSelected() {
        copySelected()
        paste()
    }

    // MARK: - Persistence

    private let canvasStore = CanvasStore()
    private var saveTask: Task<Void, Never>?

    /// Debounced auto-save — waits 500ms after last mutation, then writes.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.persistCanvas()
        }
    }

    private func persistCanvas() {
        guard let id = currentCanvasId else { return }
        canvasStore.saveCanvas(
            canvasId: id,
            nodes: nodes,
            edges: edges,
            groups: groups,
            viewportOffset: offset,
            viewportScale: scale
        )
    }

    // MARK: - Canvas lifecycle

    func loadCanvasList() {
        canvasList = canvasStore.listCanvases()
    }

    func createCanvas(title: String = "Untitled Canvas") {
        persistCanvas() // save current first
        let record = canvasStore.createCanvas(title: title)
        currentCanvasId = record.id
        nodes = []
        edges = []
        groups = []
        offset = .zero
        lastCommittedOffset = .zero
        scale = 1.0
        lastCommittedScale = 1.0
        clearSelection()
        loadCanvasList()
    }

    func switchCanvas(_ id: String) {
        guard id != currentCanvasId else { return }
        persistCanvas()
        loadCanvasContent(id: id)
        loadCanvasList()
    }

    func deleteCanvas(_ id: String) {
        canvasStore.deleteCanvas(id: id)
        if currentCanvasId == id {
            currentCanvasId = nil
            nodes = []
            edges = []
            groups = []
        }
        loadCanvasList()
    }

    func renameCanvas(_ id: String, title: String) {
        canvasStore.renameCanvas(id: id, title: title)
        loadCanvasList()
    }

    /// Load or create the default canvas on first launch.
    func ensureCanvas() {
        loadCanvasList()
        if let first = canvasList.first {
            loadCanvasContent(id: first.id)
        } else {
            let record = canvasStore.createCanvas(title: "Canvas")
            currentCanvasId = record.id
            loadCanvasList()
        }
    }

    private func loadCanvasContent(id: String) {
        guard let data = canvasStore.loadCanvas(id: id) else { return }
        currentCanvasId = data.canvas.id
        nodes = data.nodes
        edges = data.edges
        groups = data.groups
        offset = CGSize(width: data.canvas.viewportOffsetX, height: data.canvas.viewportOffsetY)
        lastCommittedOffset = offset
        scale = data.canvas.viewportScale
        lastCommittedScale = scale
        clearSelection()
    }

    // MARK: - Node CRUD

    func addNode(at canvasPoint: CGPoint, color: CanvasNode.NodeColor = .note) {
        pushUndo()
        let node = CanvasNode(position: canvasPoint, color: color)
        nodes.append(node)
        selectedIds = [node.id]
        editingNodeId = node.id
        scheduleSave()
    }

    func addChatNode(
        at canvasPoint: CGPoint,
        content: String,
        chatId: String,
        chatTitle: String,
        role: MessageRole,
        agentCategory: AgentCategory?,
        timestamp: Date
    ) {
        pushUndo()
        let origin = NodeSource.ChatOrigin(
            chatId: chatId,
            chatTitle: chatTitle,
            role: role,
            agentCategory: agentCategory,
            timestamp: timestamp
        )
        let color: CanvasNode.NodeColor = role == .user ? .idea : .reference
        let node = CanvasNode(
            position: canvasPoint,
            text: content,
            width: 260,
            color: color,
            source: .chat(origin)
        )
        nodes.append(node)
        selectedIds = [node.id]
        scheduleSave()
    }

    func addChatThread(
        messages: [ChatMessageRecord],
        chatId: String,
        chatTitle: String,
        centerAt canvasPoint: CGPoint
    ) {
        pushUndo()
        let filtered = messages.filter { $0.role == "user" || $0.role == "assistant" }
        guard !filtered.isEmpty else { return }

        var previousNodeId: UUID?
        let verticalSpacing: CGFloat = 140

        for (i, msg) in filtered.enumerated() {
            let role = MessageRole(rawValue: msg.role) ?? .user
            let agent = msg.agentCategory.flatMap { AgentCategory(rawValue: $0) }
            let position = CGPoint(
                x: canvasPoint.x,
                y: canvasPoint.y + CGFloat(i) * verticalSpacing
            )

            let origin = NodeSource.ChatOrigin(
                chatId: chatId,
                chatTitle: chatTitle,
                role: role,
                agentCategory: agent,
                timestamp: msg.createdAt
            )
            let color: CanvasNode.NodeColor = role == .user ? .idea : .reference
            let truncated = msg.content.count > 300
                ? String(msg.content.prefix(297)) + "..."
                : msg.content
            let node = CanvasNode(
                position: position,
                text: truncated,
                width: 280,
                color: color,
                source: .chat(origin)
            )
            nodes.append(node)

            if let prevId = previousNodeId {
                edges.append(CanvasEdge(fromId: prevId, toId: node.id))
            }
            previousNodeId = node.id
        }

        if let firstNew = nodes.dropFirst(nodes.count - filtered.count).first {
            selectedIds = [firstNew.id]
        }
        scheduleSave()
    }

    func deleteSelected() {
        // Cancel AI if the streaming node is being deleted
        if let streamingId = aiStreamingNodeId, selectedIds.contains(streamingId) {
            cancelAI()
        }
        pushUndo()
        let ids = selectedIds
        nodes.removeAll { ids.contains($0.id) }
        edges.removeAll { ids.contains($0.fromId) || ids.contains($0.toId) }
        // Remove nodes from groups, delete empty groups
        groups.removeAll { group in
            !nodes.contains(where: { $0.groupId == group.id })
        }
        selectedIds.removeAll()
        editingNodeId = nil
        scheduleSave()
    }

    func moveNode(id: UUID, to position: CGPoint) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[idx].position = position
    }

    func commitMove() {
        scheduleSave()
    }

    func updateText(id: UUID, text: String) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[idx].text = text
        scheduleSave()
    }

    func cycleColor(id: UUID) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        let all = CanvasNode.NodeColor.allCases
        let current = nodes[idx].color
        let nextIndex = (all.firstIndex(of: current)! + 1) % all.count
        nodes[idx].color = all[nextIndex]
        scheduleSave()
    }

    // MARK: - Edges

    func commitEdge(toId: UUID) {
        guard let fromId = pendingEdgeFromId, fromId != toId else {
            pendingEdgeFromId = nil
            return
        }
        if !edges.contains(where: { $0.fromId == fromId && $0.toId == toId }) {
            edges.append(CanvasEdge(fromId: fromId, toId: toId))
        }
        pendingEdgeFromId = nil
        scheduleSave()
    }

    func deleteEdge(id: UUID) {
        edges.removeAll { $0.id == id }
        scheduleSave()
    }

    func updateEdgeLabel(id: UUID, label: String) {
        guard let idx = edges.firstIndex(where: { $0.id == id }) else { return }
        edges[idx].label = label.isEmpty ? nil : label
        editingEdgeId = nil
        scheduleSave()
    }

    func updateEdgeStyle(id: UUID, style: CanvasEdge.EdgeStyle) {
        guard let idx = edges.firstIndex(where: { $0.id == id }) else { return }
        edges[idx].style = style
        scheduleSave()
    }

    func updateEdgeColor(id: UUID, color: CanvasEdge.EdgeColor) {
        guard let idx = edges.firstIndex(where: { $0.id == id }) else { return }
        edges[idx].color = color
        scheduleSave()
    }

    func updateEdgeDirection(id: UUID, direction: CanvasEdge.EdgeDirection) {
        guard let idx = edges.firstIndex(where: { $0.id == id }) else { return }
        edges[idx].direction = direction
        scheduleSave()
    }

    func updateEdgeWeight(id: UUID, weight: CanvasEdge.EdgeWeight) {
        guard let idx = edges.firstIndex(where: { $0.id == id }) else { return }
        edges[idx].weight = weight
        scheduleSave()
    }

    func applyEdgePreset(id: UUID, preset: EdgePreset) {
        guard let idx = edges.firstIndex(where: { $0.id == id }) else { return }
        edges[idx].label = preset.label
        edges[idx].style = preset.style
        edges[idx].color = preset.color
        edges[idx].direction = preset.direction
        scheduleSave()
    }

    // MARK: - Groups

    func groupFromSelection() {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard selected.count >= 2 else { return }
        pushUndo()

        let minX = selected.map(\.position.x).min()! - 30
        let minY = selected.map(\.position.y).min()! - 40
        let maxX = selected.map { $0.position.x + $0.width / 2 }.max()! + 30
        let maxY = selected.map(\.position.y).max()! + 60

        let group = CanvasGroup(
            position: CGPoint(x: minX, y: minY),
            size: CGSize(width: maxX - minX, height: maxY - minY)
        )
        groups.append(group)

        for id in selectedIds {
            if let idx = nodes.firstIndex(where: { $0.id == id }) {
                nodes[idx].groupId = group.id
            }
        }
        scheduleSave()
    }

    func ungroupSelected() {
        pushUndo()
        let groupIds = Set(nodes.filter { selectedIds.contains($0.id) }.compactMap(\.groupId))
        for id in selectedIds {
            if let idx = nodes.firstIndex(where: { $0.id == id }) {
                nodes[idx].groupId = nil
            }
        }
        // Remove groups that are now empty
        groups.removeAll { groupIds.contains($0.id) && !nodes.contains(where: { $0.groupId == $0.id }) }
        scheduleSave()
    }

    func moveGroup(id: UUID, delta: CGSize) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].position.x += delta.width
        groups[idx].position.y += delta.height
        // Move contained nodes
        for i in nodes.indices where nodes[i].groupId == id {
            nodes[i].position.x += delta.width
            nodes[i].position.y += delta.height
        }
    }

    func renameGroup(id: UUID, title: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].title = title
        scheduleSave()
    }

    func deleteGroup(id: UUID) {
        pushUndo()
        // Ungroup nodes, don't delete them
        for i in nodes.indices where nodes[i].groupId == id {
            nodes[i].groupId = nil
        }
        groups.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Color & Resize

    func setColor(_ color: CanvasNode.NodeColor) {
        pushUndo()
        for id in selectedIds {
            if let idx = nodes.firstIndex(where: { $0.id == id }) {
                nodes[idx].color = color
            }
        }
        scheduleSave()
    }

    func resizeSelected(width: CGFloat) {
        pushUndo()
        let clamped = max(120, min(width, 500))
        for id in selectedIds {
            if let idx = nodes.firstIndex(where: { $0.id == id }) {
                nodes[idx].width = clamped
            }
        }
        scheduleSave()
    }

    // MARK: - Alignment & Distribution

    enum CanvasAlignment { case left, centerH, right, top, centerV, bottom }

    func alignSelected(_ alignment: CanvasAlignment) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard selected.count >= 2 else { return }
        pushUndo()

        let target: CGFloat
        switch alignment {
        case .left:    target = selected.map(\.position.x).min()!
        case .centerH: target = selected.map(\.position.x).reduce(0, +) / CGFloat(selected.count)
        case .right:   target = selected.map(\.position.x).max()!
        case .top:     target = selected.map(\.position.y).min()!
        case .centerV: target = selected.map(\.position.y).reduce(0, +) / CGFloat(selected.count)
        case .bottom:  target = selected.map(\.position.y).max()!
        }

        for id in selectedIds {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { continue }
            switch alignment {
            case .left, .centerH, .right: nodes[idx].position.x = target
            case .top, .centerV, .bottom: nodes[idx].position.y = target
            }
        }
        scheduleSave()
    }

    func distributeSelected(axis: Axis) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard selected.count >= 3 else { return }
        pushUndo()

        let sorted: [CanvasNode]
        let minVal: CGFloat
        let maxVal: CGFloat

        switch axis {
        case .horizontal:
            sorted = selected.sorted { $0.position.x < $1.position.x }
            minVal = sorted.first!.position.x
            maxVal = sorted.last!.position.x
        case .vertical:
            sorted = selected.sorted { $0.position.y < $1.position.y }
            minVal = sorted.first!.position.y
            maxVal = sorted.last!.position.y
        }

        let spacing = (maxVal - minVal) / CGFloat(sorted.count - 1)
        for (i, node) in sorted.enumerated() {
            guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { continue }
            switch axis {
            case .horizontal: nodes[idx].position.x = minVal + CGFloat(i) * spacing
            case .vertical:   nodes[idx].position.y = minVal + CGFloat(i) * spacing
            }
        }
        scheduleSave()
    }

    // MARK: - AI Actions

    func invokeAI(
        action: String,
        prompt: String,
        orchestrator: Orchestrator
    ) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }

        // Position the result node to the right of the selection centroid
        let cx = selected.map(\.position.x).reduce(0, +) / CGFloat(selected.count)
        let cy = selected.map(\.position.y).reduce(0, +) / CGFloat(selected.count)
        let resultPosition = CGPoint(x: cx + 320, y: cy)

        let origin = NodeSource.AIOrigin(
            action: action,
            sourceNodeIds: selected.map(\.id),
            timestamp: Date()
        )
        let resultNode = CanvasNode(
            position: resultPosition,
            text: "",
            width: 300,
            color: .ai,
            source: .ai(origin)
        )
        nodes.append(resultNode)
        aiStreamingNodeId = resultNode.id

        // Connect selected → result
        for id in selectedIds {
            edges.append(CanvasEdge(fromId: id, toId: resultNode.id, label: action))
        }

        // Build context from selected nodes
        let context = selected.map(\.text).joined(separator: "\n\n")

        let fullPrompt = """
        The user selected these notes on their canvas:

        \(context)

        Based on the above, \(prompt)

        Respond directly with the result. Do not explain what the notes are, do not ask follow-up questions, just do it.
        """

        isProcessingAI = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas", message: fullPrompt
                ) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let chunk):
                        accumulated += chunk
                        if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                            self.nodes[idx].text = accumulated
                        }
                    case .image(let data, _):
                        if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                            var imgs = self.nodes[idx].images ?? []
                            imgs.append(data)
                            self.nodes[idx].images = imgs
                        }
                    case .status, .agentSelected:
                        break
                    }
                }
            } catch is CancellationError {
                // Cancelled — keep partial response
            } catch {
                if accumulated.isEmpty {
                    accumulated = "Error: \(error.localizedDescription)"
                    if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                        self.nodes[idx].text = accumulated
                    }
                }
            }

            self.isProcessingAI = false
            self.aiStreamingNodeId = nil
            self.aiTask = nil
            self.scheduleSave()
        }
    }

    // MARK: - Execute (zero-prompt AI)

    /// One-click AI: treats the selected nodes' text as instructions and
    /// executes them directly. No additional prompt needed.
    func executeNodes(orchestrator: Orchestrator) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }

        let cx = selected.map(\.position.x).reduce(0, +) / CGFloat(selected.count)
        let cy = selected.map(\.position.y).reduce(0, +) / CGFloat(selected.count)
        let resultPosition = CGPoint(x: cx + 320, y: cy)

        let origin = NodeSource.AIOrigin(
            action: "execute",
            sourceNodeIds: selected.map(\.id),
            timestamp: Date()
        )
        let resultNode = CanvasNode(
            position: resultPosition,
            text: "",
            width: 300,
            color: .ai,
            source: .ai(origin)
        )
        nodes.append(resultNode)
        aiStreamingNodeId = resultNode.id

        for id in selectedIds {
            edges.append(CanvasEdge(fromId: id, toId: resultNode.id))
        }

        let userText = selected.map(\.text).joined(separator: "\n\n")

        let fullPrompt = """
        You are an action-oriented AI assistant. The user wrote the following on their canvas. Treat it as a direct request or instruction and execute it immediately.

        \(userText)

        Rules:
        - If they ask for information (metrics, time, weather, data), fetch and provide it directly.
        - If they ask for code, write the code immediately.
        - If they ask for an image, generate it.
        - If they write a topic or concept, provide a thorough, useful summary.
        - If they write a question, answer it directly.
        - Never ask what they mean. Never ask follow-up questions. Just do it.
        - Format your response clearly using Markdown.
        """

        isProcessingAI = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas-exec", message: fullPrompt
                ) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let chunk):
                        accumulated += chunk
                        if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                            self.nodes[idx].text = accumulated
                        }
                    case .image(let data, _):
                        if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                            var imgs = self.nodes[idx].images ?? []
                            imgs.append(data)
                            self.nodes[idx].images = imgs
                        }
                    case .status, .agentSelected:
                        break
                    }
                }
            } catch is CancellationError {
                // Cancelled — keep partial response
            } catch {
                if accumulated.isEmpty {
                    accumulated = "Error: \(error.localizedDescription)"
                    if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                        self.nodes[idx].text = accumulated
                    }
                }
            }

            self.isProcessingAI = false
            self.aiStreamingNodeId = nil
            self.aiTask = nil
            self.scheduleSave()
        }
    }

    // MARK: - Canvas Chat (threaded conversation on canvas)

    /// Start a chat thread from a node. The chat input opens anchored to that node.
    func startChat(from nodeId: UUID) {
        chatAnchorNodeId = nodeId
        chatInputText = ""
        showCanvasChat = true
        selectedIds = [nodeId]
    }

    /// Send a message in the canvas chat. Creates a user node, then streams
    /// an AI response into a new connected node.
    func sendChatMessage(orchestrator: Orchestrator) {
        let text = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let anchorId = chatAnchorNodeId,
              let anchor = nodes.first(where: { $0.id == anchorId }) else { return }

        chatInputText = ""

        // Create user message node below the anchor
        let userPos = CGPoint(x: anchor.position.x, y: anchor.position.y + 140)
        let userNode = CanvasNode(
            position: userPos,
            text: text,
            width: 260,
            color: .idea,
            source: .manual
        )
        nodes.append(userNode)
        edges.append(CanvasEdge(fromId: anchorId, toId: userNode.id))

        // Gather thread context by walking edges backward from anchor
        let threadContext = gatherThreadContext(from: anchorId)

        // Create AI response node
        let aiPos = CGPoint(x: userNode.position.x, y: userNode.position.y + 140)
        let origin = NodeSource.AIOrigin(
            action: "chat",
            sourceNodeIds: [userNode.id],
            timestamp: Date()
        )
        let aiNode = CanvasNode(
            position: aiPos,
            text: "",
            width: 300,
            color: .ai,
            source: .ai(origin)
        )
        nodes.append(aiNode)
        edges.append(CanvasEdge(fromId: userNode.id, toId: aiNode.id))
        aiStreamingNodeId = aiNode.id
        chatAnchorNodeId = aiNode.id  // Next message continues from AI response

        let fullPrompt = """
        Previous conversation on the user's canvas:

        \(threadContext)

        User: \(text)

        Respond directly. Be concise and action-oriented.
        """

        isProcessingAI = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas-chat", message: fullPrompt
                ) {
                    if case .text(let chunk) = event {
                        accumulated += chunk
                        if let idx = self.nodes.firstIndex(where: { $0.id == aiNode.id }) {
                            self.nodes[idx].text = accumulated
                        }
                    }
                }
            } catch {
                if accumulated.isEmpty {
                    accumulated = "Error: \(error.localizedDescription)"
                    if let idx = self.nodes.firstIndex(where: { $0.id == aiNode.id }) {
                        self.nodes[idx].text = accumulated
                    }
                }
            }

            self.isProcessingAI = false
            self.aiStreamingNodeId = nil
            self.scheduleSave()
        }
    }

    /// Walk backward through edges to collect thread context from connected nodes.
    private func gatherThreadContext(from nodeId: UUID, maxDepth: Int = 10) -> String {
        var visited = Set<UUID>()
        var chain: [CanvasNode] = []

        func walkBack(_ id: UUID, depth: Int) {
            guard depth > 0, !visited.contains(id) else { return }
            visited.insert(id)
            if let node = nodes.first(where: { $0.id == id }) {
                chain.insert(node, at: 0) // prepend — oldest first
            }
            // Find edges pointing TO this node
            for edge in edges where edge.toId == id {
                walkBack(edge.fromId, depth: depth - 1)
            }
        }

        walkBack(nodeId, depth: maxDepth)

        return chain.map { node in
            let role: String
            switch node.source {
            case .ai: role = "Assistant"
            case .chat(let o) where o.role == .assistant: role = "Assistant"
            default: role = "User"
            }
            return "\(role): \(node.text)"
        }.joined(separator: "\n\n")
    }

    // MARK: - Agent Council

    /// Invoke multiple agents in parallel. Each agent's response becomes a
    /// separate node radiating from the selection centroid, creating a visual
    /// council of perspectives.
    func invokeCouncil(
        agents: [AgentCategory],
        prompt: String,
        orchestrator: Orchestrator
    ) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }

        let cx = selected.map(\.position.x).reduce(0, +) / CGFloat(selected.count)
        let cy = selected.map(\.position.y).reduce(0, +) / CGFloat(selected.count)

        // Build context from selected nodes
        let context = selected.map(\.text).joined(separator: "\n\n")

        let fullPrompt = """
        The user selected these notes on their canvas:

        \(context)

        Based on the above, \(prompt)

        Respond directly with your analysis. Do not explain what the notes are, do not ask follow-up questions.
        """

        // Create placeholder nodes for each agent, fanned out from the centroid
        let angleStep = (2.0 * .pi) / Double(agents.count)
        let radius: CGFloat = 320
        var councilNodes: [(AgentCategory, CanvasNode)] = []

        for (i, agent) in agents.enumerated() {
            let angle = angleStep * Double(i) - .pi / 2 // start from top
            let pos = CGPoint(
                x: cx + radius * cos(angle),
                y: cy + radius * sin(angle)
            )
            let origin = NodeSource.AIOrigin(
                action: agent.displayName,
                sourceNodeIds: selected.map(\.id),
                timestamp: Date()
            )
            let node = CanvasNode(
                position: pos,
                text: "",
                width: 280,
                color: .ai,
                source: .ai(origin)
            )
            nodes.append(node)
            councilNodes.append((agent, node))
            activeCouncilNodeIds.insert(node.id)

            // Connect selected nodes → this council node
            for id in selectedIds {
                edges.append(CanvasEdge(fromId: id, toId: node.id, label: agent.displayName))
            }
        }

        isProcessingAI = true

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let conv = await orchestrator.getOrCreateConversation(userId: "canvas-council")
                let results = try await orchestrator.runParallelAgents(
                    conv: conv,
                    message: fullPrompt,
                    categories: agents
                )

                for (category, response) in results {
                    if let (_, councilNode) = councilNodes.first(where: { $0.0 == category }),
                       let idx = self.nodes.firstIndex(where: { $0.id == councilNode.id }) {
                        let truncated = response.count > 600
                            ? String(response.prefix(597)) + "..."
                            : response
                        self.nodes[idx].text = truncated
                        self.activeCouncilNodeIds.remove(councilNode.id)
                    }
                }
            } catch {
                for (_, councilNode) in councilNodes {
                    if let idx = self.nodes.firstIndex(where: { $0.id == councilNode.id }),
                       self.nodes[idx].text.isEmpty {
                        self.nodes[idx].text = "Error: \(error.localizedDescription)"
                    }
                    self.activeCouncilNodeIds.remove(councilNode.id)
                }
            }

            self.isProcessingAI = false
            self.scheduleSave()
        }
    }

    // MARK: - Viewport control

    /// Zoom by a factor, keeping the given anchor point (in view coords) fixed on screen.
    func zoom(by factor: CGFloat, anchor: CGPoint) {
        let newScale = min(max(scale * factor, 0.15), 5.0)
        // The anchor point maps to a canvas point. After zoom, that canvas point
        // must still project to the same view-space anchor.
        // canvasPoint = (anchor - offset) / scale
        // newOffset   = anchor - canvasPoint * newScale
        let canvasPoint = CGPoint(
            x: (anchor.x - offset.width) / scale,
            y: (anchor.y - offset.height) / scale
        )
        offset = CGSize(
            width: anchor.x - canvasPoint.x * newScale,
            height: anchor.y - canvasPoint.y * newScale
        )
        scale = newScale
        lastCommittedOffset = offset
        lastCommittedScale = scale
    }

    /// Handle trackpad two-finger pan (includes momentum events from macOS).
    func handleTrackpadPan(deltaX: CGFloat, deltaY: CGFloat) {
        offset.width += deltaX
        offset.height += deltaY
        lastCommittedOffset = offset
    }

    /// Zoom to fit all nodes in the viewport.
    func zoomToFit() {
        guard !nodes.isEmpty else { return }
        let padding: CGFloat = 60
        let minX = nodes.map(\.position.x).min()! - padding
        let maxX = nodes.map { $0.position.x + $0.width }.max()! + padding
        let minY = nodes.map(\.position.y).min()! - padding
        let maxY = nodes.map(\.position.y).max()! + padding

        let contentW = maxX - minX
        let contentH = maxY - minY
        guard contentW > 0, contentH > 0 else { return }

        let fitScale = min(viewSize.width / contentW, viewSize.height / contentH, 2.0)
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        scale = fitScale
        lastCommittedScale = fitScale
        offset = CGSize(
            width: viewSize.width / 2 - centerX * fitScale,
            height: viewSize.height / 2 - centerY * fitScale
        )
        lastCommittedOffset = offset
    }

    // MARK: - Coordinate conversion

    func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (viewPoint.x - offset.width) / scale,
            y: (viewPoint.y - offset.height) / scale
        )
    }

    func canvasToView(_ canvasPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasPoint.x * scale + offset.width,
            y: canvasPoint.y * scale + offset.height
        )
    }

    // MARK: - Selection helpers

    func select(_ id: UUID, exclusive: Bool = true) {
        if exclusive {
            selectedIds = [id]
        } else {
            if selectedIds.contains(id) {
                selectedIds.remove(id)
            } else {
                selectedIds.insert(id)
            }
        }
    }

    func selectAll() {
        selectedIds = Set(nodes.map(\.id))
    }

    func clearSelection() {
        selectedIds.removeAll()
        editingNodeId = nil
        editingEdgeId = nil
    }
}
