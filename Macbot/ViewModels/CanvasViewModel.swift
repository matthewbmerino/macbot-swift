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

    /// The 3D node currently "entered" for interactive camera control.
    var entered3DNodeId: UUID?

    // MARK: - Universal Search

    var showSearch = false
    var searchQuery = ""
    var searchResults: [CanvasStore.SearchResult] = []

    func performSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            searchResults = []
            return
        }
        searchResults = canvasStore.searchNodes(query: q)
    }

    func navigateToSearchResult(_ result: CanvasStore.SearchResult) {
        // Switch to the canvas containing the result
        if result.canvasId != currentCanvasId {
            switchCanvas(result.canvasId)
        }
        // Select and center on the node
        if let nodeId = UUID(uuidString: result.nodeId) {
            selectedIds = [nodeId]
            if let node = nodes.first(where: { $0.id == nodeId }) {
                withAnimation(Motion.smooth) {
                    offset = CGSize(
                        width: viewSize.width / 2 - node.position.x * scale,
                        height: viewSize.height / 2 - node.position.y * scale
                    )
                    lastCommittedOffset = offset
                }
            }
        }
        showSearch = false
        searchQuery = ""
        searchResults = []
    }

    // MARK: - Export

    func exportAsMarkdown() -> String {
        var md = "# \(canvasList.first(where: { $0.id == currentCanvasId })?.title ?? "Canvas")\n\n"

        for node in nodes {
            let typeLabel = node.color.rawValue.capitalized
            md += "## \(typeLabel)\n\n"
            if !node.text.isEmpty {
                md += node.text + "\n\n"
            }

            // Show edges from this node
            let outgoing = edges.filter { $0.fromId == node.id }
            for edge in outgoing {
                if let target = nodes.first(where: { $0.id == edge.toId }) {
                    let label = edge.label ?? "→"
                    let preview = String(target.text.prefix(60))
                    md += "- **\(label)** \(preview)\n"
                }
            }
            if !outgoing.isEmpty { md += "\n" }
            md += "---\n\n"
        }
        return md
    }

    func exportMarkdownToFile() {
        let md = exportAsMarkdown()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(canvasList.first(where: { $0.id == currentCanvasId })?.title ?? "Canvas").md"
        if panel.runModal() == .OK, let url = panel.url {
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Node open in full-window editor.
    var fullEditorNodeId: UUID?
    var fullEditorText: String = ""

    func openFullEditor(nodeId: UUID) {
        guard let node = nodes.first(where: { $0.id == nodeId }) else { return }
        fullEditorNodeId = nodeId
        fullEditorText = node.text
    }

    func closeFullEditor(save: Bool = true) {
        if save, let id = fullEditorNodeId,
           let idx = nodes.firstIndex(where: { $0.id == id }) {
            pushUndo()
            nodes[idx].text = fullEditorText
            scheduleSave()
        }
        fullEditorNodeId = nil
        fullEditorText = ""
    }

    func enter3DNode(id: UUID) {
        entered3DNodeId = id
    }

    func exit3DNode() {
        entered3DNodeId = nil
    }

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
    var aiTask: Task<Void, Never>?

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

    // MARK: - Persistence (implementation in CanvasViewModel+Persistence.swift)

    let canvasStore = CanvasStore()
    var saveTask: Task<Void, Never>?

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
    func pushUndo() {
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


    // Persistence, canvas lifecycle, and save logic are in CanvasViewModel+Persistence.swift
    // Node/edge/group CRUD and transforms are in CanvasViewModel+Editing.swift
    // AI actions, execute, chat, council are in CanvasViewModel+AI.swift

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
