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

    // MARK: - Selection & interaction

    var selectedIds: Set<UUID> = []
    var editingNodeId: UUID?
    var draggingNodeId: UUID?
    var editingEdgeId: UUID?
    var editingEdgeLabel: String = ""

    /// When non-nil the user is dragging from a node port to create an edge.
    var pendingEdgeFromId: UUID?
    var pendingEdgeEnd: CGPoint = .zero

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

    // MARK: - Canvas Chat

    /// The node that the canvas chat is anchored to (reply thread).
    var chatAnchorNodeId: UUID?
    var chatInputText: String = ""
    var showCanvasChat: Bool = false

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
        clearSelection()
    }

    // MARK: - Node CRUD

    func addNode(at canvasPoint: CGPoint, color: CanvasNode.NodeColor = .note) {
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

    // MARK: - Groups

    func groupFromSelection() {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard selected.count >= 2 else { return }

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
        // Ungroup nodes, don't delete them
        for i in nodes.indices where nodes[i].groupId == id {
            nodes[i].groupId = nil
        }
        groups.removeAll { $0.id == id }
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
        let context = selected.map { node in
            let label = node.color.rawValue.uppercased()
            return "[\(label)] \(node.text)"
        }.joined(separator: "\n---\n")

        let fullPrompt = """
        Context from my canvas notes:

        \(context)

        \(prompt)
        """

        isProcessingAI = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas", message: fullPrompt
                ) {
                    switch event {
                    case .text(let chunk):
                        accumulated += chunk
                        if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                            self.nodes[idx].text = accumulated
                        }
                    case .status, .agentSelected, .image:
                        break
                    }
                }
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
        Previous conversation context:

        \(threadContext)

        User: \(text)
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
        let context = selected.map { node in
            let label = node.color.rawValue.uppercased()
            return "[\(label)] \(node.text)"
        }.joined(separator: "\n---\n")

        let fullPrompt = """
        Context from canvas notes:

        \(context)

        \(prompt)
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
