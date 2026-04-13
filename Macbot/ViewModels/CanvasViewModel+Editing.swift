import Foundation
import SwiftUI

extension CanvasViewModel {
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

    // MARK: - 3D Viewport Detach / Reattach

    /// Pull the 3D viewport out of a card node into a free-floating viewport node.
    func detach3DViewport(nodeId: UUID) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }),
              let sceneData = nodes[idx].sceneData else { return }
        pushUndo()

        let source = nodes[idx]
        // Clear scene from card
        nodes[idx].sceneData = nil

        // Create free-floating 3D node
        let viewportNode = CanvasNode(
            position: CGPoint(x: source.position.x + 340, y: source.position.y),
            text: "",
            width: 300,
            color: .ai,
            source: source.source,
            sceneData: sceneData
        )
        // Set display mode and height after init
        var mutableNode = viewportNode
        mutableNode.displayMode = .viewport3D
        mutableNode.viewportHeight = 300
        nodes.append(mutableNode)

        edges.append(CanvasEdge(fromId: nodeId, toId: mutableNode.id, label: "3D", style: .dashed, color: .neutral))
        selectedIds = [mutableNode.id]
        scheduleSave()
    }

    /// Reattach a free-floating 3D viewport back into a card node.
    func reattachToCard(nodeId: UUID) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }),
              nodes[idx].displayMode == .viewport3D else { return }
        pushUndo()
        nodes[idx].displayMode = .card
        scheduleSave()
    }

    func resizeViewport(id: UUID, height: CGFloat) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[idx].viewportHeight = max(150, min(height, 600))
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

}
