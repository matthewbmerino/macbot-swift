import Foundation
import SwiftUI

extension CanvasViewModel {
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
        let selectedImages = selected.flatMap { $0.images ?? [] }
        let hasImages = !selectedImages.isEmpty

        let fullPrompt = """
        The user selected these notes on their canvas:

        \(context)
        \(hasImages ? "\n[The user has also attached \(selectedImages.count) image(s) to these notes. Analyze them as part of the context.]\n" : "")
        Based on the above, \(prompt)

        Respond directly with the result. Do not explain what the notes are, do not ask follow-up questions, just do it.
        """

        isProcessingAI = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas", message: fullPrompt,
                    images: hasImages ? selectedImages : nil
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

    // MARK: - Execute (unified smart AI)

    /// Unified execute: the AI decides the response shape.
    /// - Simple answers → single card
    /// - Complex topics → multiple cards created progressively as sections stream in
    /// - 3D requests → scene node
    /// Non-blocking: source nodes show a processing badge while AI works.
    func executeNodes(orchestrator: Orchestrator) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }

        let sourceIds = Set(selected.map(\.id))
        let cx = selected.map(\.position.x).reduce(0, +) / CGFloat(selected.count)
        let cy = selected.map(\.position.y).reduce(0, +) / CGFloat(selected.count)

        let userText = selected.map(\.text).joined(separator: "\n\n")
        let selectedImages = selected.flatMap { $0.images ?? [] }
        let hasImages = !selectedImages.isEmpty

        // 3D requests use the old single-node path
        if Self.is3DRequest(userText) {
            execute3DRequest(userText, cx: cx, cy: cy, sourceIds: sourceIds, orchestrator: orchestrator)
            return
        }

        let fullPrompt = """
        The user wrote this on their canvas:

        \(userText)
        \(hasImages ? "\n[\(selectedImages.count) image(s) attached — analyze them.]\n" : "")
        You MUST structure your response as multiple separate sections using ## headers.
        Each section becomes its own card on the user's canvas, forming a knowledge graph.

        Rules:
        - ALWAYS use ## headers. Every piece of information gets its own ## section.
        - Create 5-12 sections. More is better. Each should be SHORT (2-4 sentences).
        - Think like a researcher building a knowledge map: separate facts, concepts, people, dates, implications, questions.
        - Each section = one focused idea, fact, or concept. NOT a wall of text.
        - Use bullets within sections for key points.
        - Never combine unrelated information in one section.
        - Never ask follow-up questions. Just do it.

        Example structure:
        ## Overview
        Brief summary of the topic.

        ## Key Fact 1
        A specific important fact.

        ## Key Person/Entity
        Who is involved and why.

        ## Timeline
        When things happened.

        ## Implications
        What this means going forward.

        Now respond about: \(userText)
        """

        // Mark source nodes as processing
        processingSourceIds = sourceIds
        isProcessingAI = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            var flushedSections: [String] = []   // titles of sections already turned into cards
            var createdNodeIds: [UUID] = []
            var sectionIndex = 0

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas-exec", message: fullPrompt,
                    images: hasImages ? selectedImages : nil
                ) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let chunk):
                        accumulated += chunk

                        // Check for completed sections: when we see a new ## header,
                        // everything before it is a complete section
                        let completedSections = self.extractCompletedSections(
                            from: accumulated, alreadyFlushed: flushedSections.count
                        )

                        for section in completedSections {
                            let pos = self.sectionPosition(
                                index: sectionIndex, total: 10,
                                centerX: cx + 340, centerY: cy
                            )
                            let nodeId = self.createSectionCard(
                                title: section.title,
                                content: section.content,
                                position: pos,
                                sourceIds: sourceIds
                            )
                            createdNodeIds.append(nodeId)
                            flushedSections.append(section.title)
                            sectionIndex += 1
                        }

                    case .image(let data, _):
                        // Attach image to the most recent card, or first source
                        if let lastId = createdNodeIds.last,
                           let idx = self.nodes.firstIndex(where: { $0.id == lastId }) {
                            var imgs = self.nodes[idx].images ?? []
                            imgs.append(data)
                            self.nodes[idx].images = imgs
                        }
                    case .status, .agentSelected:
                        break
                    }
                }

                // Flush the final section (no trailing ## header to trigger it)
                let finalSections = self.extractAllSections(
                    from: accumulated, alreadyFlushed: flushedSections.count
                )
                for section in finalSections {
                    let pos = self.sectionPosition(
                        index: sectionIndex, total: max(sectionIndex + 1, finalSections.count),
                        centerX: cx + 340, centerY: cy
                    )
                    let nodeId = self.createSectionCard(
                        title: section.title,
                        content: section.content,
                        position: pos,
                        sourceIds: sourceIds
                    )
                    createdNodeIds.append(nodeId)
                    sectionIndex += 1
                }

                // If no sections were created (short/simple response), create a single card
                if createdNodeIds.isEmpty && !accumulated.isEmpty {
                    let pos = CGPoint(x: cx + 340, y: cy)
                    let nodeId = self.createSectionCard(
                        title: "",
                        content: accumulated.trimmingCharacters(in: .whitespacesAndNewlines),
                        position: pos,
                        sourceIds: sourceIds
                    )
                    createdNodeIds.append(nodeId)
                }

                // Select all new cards + source nodes, then zoom to show everything
                if !createdNodeIds.isEmpty {
                    self.selectedIds = Set(createdNodeIds).union(sourceIds)
                    // Brief delay so cards are laid out before zoom calculates bounds
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation(Motion.smooth) {
                        self.zoomToSelection()
                    }
                    // Then select only the new cards (not sources)
                    self.selectedIds = Set(createdNodeIds)
                }

            } catch is CancellationError {
                // Keep what we have
            } catch {
                let pos = CGPoint(x: cx + 340, y: cy)
                _ = self.createSectionCard(
                    title: "",
                    content: "Error: \(error.localizedDescription)",
                    position: pos,
                    sourceIds: sourceIds
                )
            }

            self.processingSourceIds.removeAll()
            self.isProcessingAI = false
            self.aiStreamingNodeId = nil
            self.aiTask = nil
            self.scheduleSave()
        }
    }

    // MARK: - Streaming Section Parser

    struct ParsedSection {
        let title: String
        let content: String
    }

    /// Extract sections that are fully complete (followed by another ## header).
    /// Returns only NEW sections not yet flushed.
    private func extractCompletedSections(from text: String, alreadyFlushed: Int) -> [ParsedSection] {
        let allSections = parseMarkdownSections(text)
        // A section is "complete" if there's another section after it
        guard allSections.count > 1 else { return [] }
        // Return unflushed completed sections (all except the last, which may still be streaming)
        let completed = Array(allSections.dropLast())
        return Array(completed.dropFirst(alreadyFlushed))
    }

    /// Extract ALL sections including the final one (called at end of stream).
    private func extractAllSections(from text: String, alreadyFlushed: Int) -> [ParsedSection] {
        let allSections = parseMarkdownSections(text)
        return Array(allSections.dropFirst(alreadyFlushed))
    }

    /// Parse markdown text into sections split by ## headers.
    private func parseMarkdownSections(_ text: String) -> [ParsedSection] {
        let lines = text.components(separatedBy: "\n")
        var sections: [ParsedSection] = []
        var currentTitle = ""
        var currentLines: [String] = []
        var hasAnySections = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                hasAnySections = true
                // Flush previous section
                if !currentTitle.isEmpty || !currentLines.isEmpty {
                    let content = currentLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty || !currentTitle.isEmpty {
                        sections.append(ParsedSection(title: currentTitle, content: content))
                    }
                }
                currentTitle = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        // Don't forget trailing content
        if hasAnySections {
            let content = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty || !currentTitle.isEmpty {
                sections.append(ParsedSection(title: currentTitle, content: content))
            }
        }

        return sections
    }

    /// Create a card from a parsed section and connect it to sources.
    @discardableResult
    private func createSectionCard(
        title: String,
        content: String,
        position: CGPoint,
        sourceIds: Set<UUID>
    ) -> UUID {
        let nodeId = UUID()
        let text: String
        if title.isEmpty {
            text = content
        } else {
            text = "## \(title)\n\n\(content)"
        }

        let origin = NodeSource.AIOrigin(
            action: "execute",
            sourceNodeIds: Array(sourceIds),
            timestamp: Date()
        )
        let node = CanvasNode(
            id: nodeId,
            position: position,
            text: text,
            width: 280,
            color: .ai,
            source: .ai(origin)
        )

        withAnimation(Motion.snappy) {
            nodes.append(node)

            // Every card connects directly to source nodes (star pattern — clean, no tangling)
            for sourceId in sourceIds {
                edges.append(CanvasEdge(fromId: sourceId, toId: nodeId))
            }
        }

        return nodeId
    }

    /// Position for the Nth section card — clean 2-column grid to the right of source.
    /// Wide spacing prevents overlap. Cards flow top-to-bottom, left-to-right.
    private func sectionPosition(index: Int, total: Int, centerX: CGFloat, centerY: CGFloat) -> CGPoint {
        let cols = min(total > 4 ? 2 : 1, 2)  // 1 column for ≤4 cards, 2 for more
        let colSpacing: CGFloat = 360          // 280pt card + 80pt gap
        let rowSpacing: CGFloat = 300          // generous vertical gap for tall cards

        let col = index % cols
        let row = index / cols

        let totalRows = CGFloat((total + cols - 1) / cols)

        // Start from top, offset right of source — don't center over it
        let startY = centerY - (totalRows - 1) * rowSpacing / 2

        return CGPoint(
            x: centerX + CGFloat(col) * colSpacing,
            y: startY + CGFloat(row) * rowSpacing
        )
    }

    // MARK: - Widget Execute (in-place response)

    /// Execute a node in widget mode — AI response replaces the card content in-place.
    /// The original prompt is preserved so the user can toggle back to edit and re-run.
    func executeWidget(nodeId: UUID, orchestrator: Orchestrator) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }

        pushUndo()
        let prompt = nodes[idx].text
        let nodeImages = nodes[idx].images ?? []
        let hasImages = !nodeImages.isEmpty

        // Store original prompt and set loading state
        nodes[idx].originalPrompt = prompt
        nodes[idx].widgetState = .loading
        processingSourceIds = [nodeId]
        isProcessingAI = true

        let fullPrompt = """
        The user asks:

        \(prompt)
        \(hasImages ? "\n[\(nodeImages.count) image(s) attached — analyze them.]\n" : "")
        Respond directly and concisely. This is a quick answer card, not a research paper.
        Use markdown formatting. Be precise and useful. No filler.
        """

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "widget-\(nodeId)",
                    message: fullPrompt,
                    images: hasImages ? nodeImages : nil
                ) {
                    try Task.checkCancellation()
                    if case .text(let chunk) = event {
                        accumulated += chunk
                        if let i = self.nodes.firstIndex(where: { $0.id == nodeId }) {
                            self.nodes[i].text = accumulated
                        }
                    }
                    if case .image(let data, _) = event {
                        if let i = self.nodes.firstIndex(where: { $0.id == nodeId }) {
                            var imgs = self.nodes[i].images ?? []
                            imgs.append(data)
                            self.nodes[i].images = imgs
                        }
                    }
                }
                if let i = self.nodes.firstIndex(where: { $0.id == nodeId }) {
                    self.nodes[i].widgetState = .result
                }
            } catch is CancellationError {
                if let i = self.nodes.firstIndex(where: { $0.id == nodeId }) {
                    self.nodes[i].widgetState = accumulated.isEmpty ? .idle : .result
                }
            } catch {
                if let i = self.nodes.firstIndex(where: { $0.id == nodeId }) {
                    self.nodes[i].text = "Error: \(error.localizedDescription)"
                    self.nodes[i].widgetState = .error
                }
            }

            self.processingSourceIds.removeAll()
            self.isProcessingAI = false
            self.aiStreamingNodeId = nil
            self.aiTask = nil
            self.scheduleSave()
        }
    }

    /// Restore a widget card back to its original prompt for editing.
    func widgetEditPrompt(nodeId: UUID) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }),
              let original = nodes[idx].originalPrompt else { return }
        pushUndo()
        nodes[idx].text = original
        nodes[idx].widgetState = .idle
        nodes[idx].originalPrompt = nil
        editingNodeId = nodeId
    }

    /// Re-run a widget card with its stored prompt.
    func widgetRerun(nodeId: UUID, orchestrator: Orchestrator) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }),
              let original = nodes[idx].originalPrompt else { return }
        nodes[idx].text = original
        nodes[idx].widgetState = .idle
        executeWidget(nodeId: nodeId, orchestrator: orchestrator)
    }

    // MARK: - 3D Execute (separate path)

    private func execute3DRequest(_ userText: String, cx: CGFloat, cy: CGFloat, sourceIds: Set<UUID>, orchestrator: Orchestrator) {
        let resultPosition = CGPoint(x: cx + 320, y: cy)
        let origin = NodeSource.AIOrigin(action: "execute", sourceNodeIds: Array(sourceIds), timestamp: Date())
        let resultNode = CanvasNode(position: resultPosition, text: "", width: 320, color: .ai, source: .ai(origin))
        nodes.append(resultNode)
        aiStreamingNodeId = resultNode.id
        for id in sourceIds { edges.append(CanvasEdge(fromId: id, toId: resultNode.id)) }

        let fullPrompt = """
        The user wants a 3D object or scene. Respond ONLY with a JSON code block describing the scene. No other text.

        ```json
        {"objects":[{"shape":"sphere","size":1.0,"color":"#4499DD","metalness":0.3,"roughness":0.4,"position":{"x":0,"y":0,"z":0}}],"cameraDistance":5.0,"showFloor":true}
        ```

        Available shapes: sphere, box, cylinder, cone, torus, plane, pyramid, capsule, tube, text3D
        User request: \(userText)
        Respond with ONLY the JSON code block.
        """

        processingSourceIds = sourceIds
        isProcessingAI = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                for try await event in orchestrator.handleMessageStream(userId: "canvas-exec", message: fullPrompt) {
                    try Task.checkCancellation()
                    if case .text(let chunk) = event {
                        accumulated += chunk
                        if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                            self.nodes[idx].text = accumulated
                            if let scene = Self.parseSceneJSON(accumulated) {
                                self.nodes[idx].sceneData = scene
                            }
                        }
                    }
                }
                if let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }),
                   let scene = Self.parseSceneJSON(accumulated) {
                    self.nodes[idx].sceneData = scene
                    self.nodes[idx].text = ""
                }
            } catch { /* keep partial */ }

            self.processingSourceIds.removeAll()
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
        // Collect images from all nodes in the thread + anchor
        let threadImages = gatherThreadImages(from: anchorId)
        let hasImages = !threadImages.isEmpty

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
        \(hasImages ? "\n[There are \(threadImages.count) image(s) attached to nodes in this thread. Use them as context.]\n" : "")
        User: \(text)

        Respond directly. Be concise and action-oriented.
        """

        isProcessingAI = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas-chat", message: fullPrompt,
                    images: hasImages ? threadImages : nil
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

    /// Collect images from all nodes in the thread leading to this node.
    private func gatherThreadImages(from nodeId: UUID, maxDepth: Int = 10) -> [Data] {
        var visited = Set<UUID>()
        var images: [Data] = []

        func walkBack(_ id: UUID, depth: Int) {
            guard depth > 0, !visited.contains(id) else { return }
            visited.insert(id)
            if let node = nodes.first(where: { $0.id == id }) {
                if let nodeImages = node.images {
                    images.append(contentsOf: nodeImages)
                }
            }
            for edge in edges where edge.toId == id {
                walkBack(edge.fromId, depth: depth - 1)
            }
        }

        walkBack(nodeId, depth: maxDepth)
        return images
    }

    // MARK: - Multi-node Orchestration

    /// Orchestration action definitions.
    enum OrchestrationAction: String {
        case decompose
        case researchMap = "research"
        case branchIdeas = "branch"
        case planSteps = "plan"
        case factSheet = "factsheet"

        var displayName: String {
            switch self {
            case .decompose: return "Decompose"
            case .researchMap: return "Research & Map"
            case .branchIdeas: return "Branch Ideas"
            case .planSteps: return "Plan Steps"
            case .factSheet: return "Fact Sheet"
            }
        }

        var prompt: String {
            switch self {
            case .decompose:
                return """
                Break this content into separate, distinct topics or sections. Each should be a self-contained note \
                that stands on its own. Create edges showing how the pieces relate to each other.
                """
            case .researchMap:
                return """
                Research this topic thoroughly. Create a knowledge map with separate nodes for: \
                key facts, related concepts, important people/organizations, timeline/history, \
                and current relevance. Connect them with labeled edges showing relationships.
                """
            case .branchIdeas:
                return """
                Take this idea and branch it into multiple directions. Explore different angles, \
                perspectives, interpretations, and possibilities. Each branch should be a distinct \
                line of thinking. Connect related branches.
                """
            case .planSteps:
                return """
                Break this into an actionable plan. Create separate nodes for each phase or step. \
                Use edges to show dependencies and sequence. Include a node for prerequisites \
                and a node for the end goal.
                """
            case .factSheet:
                return """
                Create a comprehensive fact sheet broken into separate cards. Include nodes for: \
                overview/summary, key facts & figures, important dates, key people/organizations, \
                and notable details. Connect related facts.
                """
            }
        }
    }

    /// JSON structure the AI returns for multi-node output.
    private struct OrchestrationResult: Codable {
        struct NodeDef: Codable {
            let id: String
            let title: String
            let content: String
            let color: String?     // "note", "idea", "task", "reference", "ai"
        }
        struct EdgeDef: Codable {
            let from: String
            let to: String
            let label: String?
        }
        let nodes: [NodeDef]
        let edges: [EdgeDef]?
    }

    /// Run multi-node AI orchestration. The AI creates a network of connected nodes.
    func orchestrateAI(
        action: OrchestrationAction,
        orchestrator: Orchestrator
    ) {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }

        let cx = selected.map(\.position.x).reduce(0, +) / CGFloat(selected.count)
        let cy = selected.map(\.position.y).reduce(0, +) / CGFloat(selected.count)

        let context = selected.map(\.text).joined(separator: "\n\n")
        let selectedImages = selected.flatMap { $0.images ?? [] }
        let hasImages = !selectedImages.isEmpty

        let fullPrompt = """
        Notes:
        \(context)
        \(hasImages ? "\n[\(selectedImages.count) image(s) attached — analyze them.]\n" : "")
        Task: \(action.prompt)

        Respond with ONLY a JSON code block. No text before or after.

        ```json
        {"nodes":[{"id":"1","title":"Title","content":"Details here.","color":"note"}],"edges":[{"from":"1","to":"2","label":"relates to"}]}
        ```

        - Create 3-5 nodes. Keep content to 2-4 sentences each.
        - Colors: "note", "idea", "task", "reference"
        - Edges are optional. Only add if the relationship is clear.
        - ONLY the JSON block. Nothing else.
        """

        // Create a temporary "thinking" node
        let thinkingNode = CanvasNode(
            position: CGPoint(x: cx + 320, y: cy),
            text: "Orchestrating...",
            width: 200,
            color: .ai,
            source: .ai(NodeSource.AIOrigin(
                action: action.displayName,
                sourceNodeIds: selected.map(\.id),
                timestamp: Date()
            ))
        )
        nodes.append(thinkingNode)
        aiStreamingNodeId = thinkingNode.id
        isProcessingAI = true

        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var accumulated = ""

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: "canvas-orchestrate", message: fullPrompt,
                    images: hasImages ? selectedImages : nil
                ) {
                    try Task.checkCancellation()
                    if case .text(let chunk) = event {
                        accumulated += chunk
                        // Show progress in the thinking node
                        if let idx = self.nodes.firstIndex(where: { $0.id == thinkingNode.id }) {
                            let lineCount = accumulated.components(separatedBy: "\n").count
                            self.nodes[idx].text = "Orchestrating... (\(lineCount) lines)"
                        }
                    }
                }

                // Parse and create the node network
                if let result = self.parseOrchestrationResult(accumulated) {
                    self.createNodeNetwork(
                        result: result,
                        centerX: cx + 320,
                        centerY: cy,
                        sourceNodeIds: selected.map(\.id),
                        action: action.displayName
                    )
                    // Remove the thinking node
                    self.nodes.removeAll { $0.id == thinkingNode.id }
                    self.edges.removeAll { $0.fromId == thinkingNode.id || $0.toId == thinkingNode.id }
                } else {
                    // Parsing failed — show the raw response in the thinking node
                    if let idx = self.nodes.firstIndex(where: { $0.id == thinkingNode.id }) {
                        self.nodes[idx].text = accumulated
                        self.nodes[idx].width = 300
                    }
                    // Still connect source → result
                    for id in self.selectedIds {
                        self.edges.append(CanvasEdge(fromId: id, toId: thinkingNode.id))
                    }
                }
            } catch is CancellationError {
                // Keep partial
            } catch {
                if let idx = self.nodes.firstIndex(where: { $0.id == thinkingNode.id }) {
                    self.nodes[idx].text = "Error: \(error.localizedDescription)"
                }
            }

            self.isProcessingAI = false
            self.aiStreamingNodeId = nil
            self.aiTask = nil
            self.scheduleSave()
        }
    }

    /// Parse the AI's JSON response into an OrchestrationResult.
    /// Falls back to markdown extraction if JSON parsing fails.
    private func parseOrchestrationResult(_ text: String) -> OrchestrationResult? {
        // Strategy 1: Extract JSON from markdown code fences
        if let result = parseJSON(from: text) { return result }

        // Strategy 2: Try the raw text as JSON (no fences)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let result = decodeJSON(trimmed) { return result }

        // Strategy 3: Try lenient JSON — find first { to last }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            let slice = String(text[start...end])
            if let result = decodeJSON(slice) { return result }
        }

        // Strategy 4: Fallback — extract markdown headers as nodes
        return extractNodesFromMarkdown(text)
    }

    private func parseJSON(from text: String) -> OrchestrationResult? {
        // Try ```json ... ``` then ``` ... ```
        let patterns: [(String, String)] = [("```json", "```"), ("```", "```")]
        for (open, close) in patterns {
            guard let start = text.range(of: open) else { continue }
            let searchRange = start.upperBound..<text.endIndex
            guard let end = text.range(of: close, range: searchRange) else { continue }
            let json = String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let result = decodeJSON(json) { return result }
        }
        return nil
    }

    private func decodeJSON(_ json: String) -> OrchestrationResult? {
        guard let data = json.data(using: .utf8) else { return nil }

        // Try strict decode first
        if let result = try? JSONDecoder().decode(OrchestrationResult.self, from: data) {
            return result
        }

        // Lenient decode — handle missing fields, bad colors, partial structures
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawNodes = raw["nodes"] as? [[String: Any]], !rawNodes.isEmpty else {
            return nil
        }

        let validColors = Set(["note", "idea", "task", "reference", "ai"])

        let nodeDefs: [OrchestrationResult.NodeDef] = rawNodes.enumerated().compactMap { i, dict in
            let id = (dict["id"] as? String) ?? "\(i + 1)"
            let title = (dict["title"] as? String) ?? ""
            let content = (dict["content"] as? String) ?? (dict["text"] as? String) ?? title
            let rawColor = (dict["color"] as? String) ?? "note"
            let color = validColors.contains(rawColor) ? rawColor : "note"
            guard !title.isEmpty || !content.isEmpty else { return nil }
            return OrchestrationResult.NodeDef(id: id, title: title, content: content, color: color)
        }
        guard !nodeDefs.isEmpty else { return nil }

        let edgeDefs: [OrchestrationResult.EdgeDef]? = (raw["edges"] as? [[String: Any]])?.compactMap { dict in
            guard let from = dict["from"] as? String,
                  let to = dict["to"] as? String else { return nil }
            return OrchestrationResult.EdgeDef(from: from, to: to, label: dict["label"] as? String)
        }

        return OrchestrationResult(nodes: nodeDefs, edges: edgeDefs)
    }

    /// Last-resort fallback: extract sections from markdown-formatted text.
    private func extractNodesFromMarkdown(_ text: String) -> OrchestrationResult? {
        let lines = text.components(separatedBy: "\n")
        var currentTitle = ""
        var currentContent: [String] = []
        var nodeDefs: [OrchestrationResult.NodeDef] = []

        func flushNode() {
            let content = currentContent.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentTitle.isEmpty || !content.isEmpty {
                let id = "\(nodeDefs.count + 1)"
                nodeDefs.append(OrchestrationResult.NodeDef(
                    id: id,
                    title: currentTitle,
                    content: content.isEmpty ? currentTitle : content,
                    color: "note"
                ))
            }
            currentTitle = ""
            currentContent = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("### ") {
                flushNode()
                currentTitle = trimmed.replacingOccurrences(of: "^#{1,3}\\s*", with: "", options: .regularExpression)
            } else if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") {
                flushNode()
            } else {
                currentContent.append(line)
            }
        }
        flushNode()

        // If no headers found, split by double newlines
        if nodeDefs.isEmpty {
            let paragraphs = text.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard paragraphs.count >= 2 else { return nil }

            for (i, para) in paragraphs.prefix(6).enumerated() {
                let firstLine = para.components(separatedBy: "\n").first ?? para
                let title = String(firstLine.prefix(60))
                nodeDefs.append(OrchestrationResult.NodeDef(
                    id: "\(i + 1)", title: title, content: para, color: "note"
                ))
            }
        }

        guard nodeDefs.count >= 2 else { return nil }

        // Auto-generate sequential edges
        var edgeDefs: [OrchestrationResult.EdgeDef] = []
        for i in 0..<(nodeDefs.count - 1) {
            edgeDefs.append(OrchestrationResult.EdgeDef(
                from: nodeDefs[i].id, to: nodeDefs[i + 1].id, label: nil
            ))
        }

        return OrchestrationResult(nodes: nodeDefs, edges: edgeDefs)
    }

    /// Create a network of nodes on the canvas from the parsed orchestration result.
    private func createNodeNetwork(
        result: OrchestrationResult,
        centerX: CGFloat,
        centerY: CGFloat,
        sourceNodeIds: [UUID],
        action: String
    ) {
        pushUndo()

        let count = result.nodes.count
        guard count > 0 else { return }

        // Layout: radial for ≤6 nodes, grid for more
        let positions: [CGPoint]
        if count <= 6 {
            // Radial layout around center
            let radius: CGFloat = 200 + CGFloat(count) * 20
            positions = (0..<count).map { i in
                let angle = (CGFloat(i) / CGFloat(count)) * 2 * .pi - .pi / 2
                return CGPoint(
                    x: centerX + radius * cos(angle),
                    y: centerY + radius * sin(angle)
                )
            }
        } else {
            // Grid layout
            let cols = Int(ceil(sqrt(Double(count))))
            let spacing: CGFloat = 320
            positions = (0..<count).map { i in
                let col = i % cols
                let row = i / cols
                return CGPoint(
                    x: centerX + CGFloat(col) * spacing,
                    y: centerY + CGFloat(row) * 220
                )
            }
        }

        // Create nodes, mapping the AI's string IDs to real UUIDs
        var idMap: [String: UUID] = [:]
        var newNodeIds: [UUID] = []

        for (i, nodeDef) in result.nodes.enumerated() {
            let nodeId = UUID()
            idMap[nodeDef.id] = nodeId

            let color = CanvasNode.NodeColor(rawValue: nodeDef.color ?? "note") ?? .note
            let text: String
            if nodeDef.title.isEmpty {
                text = nodeDef.content
            } else {
                text = "## \(nodeDef.title)\n\n\(nodeDef.content)"
            }

            let node = CanvasNode(
                id: nodeId,
                position: positions[i],
                text: text,
                width: 280,
                color: color,
                source: .ai(NodeSource.AIOrigin(
                    action: action,
                    sourceNodeIds: sourceNodeIds,
                    timestamp: Date()
                ))
            )
            nodes.append(node)
            newNodeIds.append(nodeId)
        }

        // Create edges between orchestrated nodes
        if let edgeDefs = result.edges {
            for edgeDef in edgeDefs {
                if let fromId = idMap[edgeDef.from],
                   let toId = idMap[edgeDef.to] {
                    let edge = CanvasEdge(
                        fromId: fromId,
                        toId: toId,
                        label: edgeDef.label,
                        style: .solid,
                        color: .neutral,
                        direction: .forward
                    )
                    edges.append(edge)
                }
            }
        }

        // Connect source nodes to the first orchestrated node (hub)
        if let hubId = newNodeIds.first {
            for sourceId in sourceNodeIds {
                edges.append(CanvasEdge(
                    fromId: sourceId,
                    toId: hubId,
                    label: action.lowercased()
                ))
            }
        }

        // Select all new nodes
        selectedIds = Set(newNodeIds)
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
    /// Pass `animated: true` for discrete mouse-wheel steps to get a brief spring animation.
    func zoom(by factor: CGFloat, anchor: CGPoint, animated: Bool = false) {
        let apply = {
            let newScale = min(max(self.scale * factor, 0.15), 5.0)
            let canvasPoint = CGPoint(
                x: (anchor.x - self.offset.width) / self.scale,
                y: (anchor.y - self.offset.height) / self.scale
            )
            self.offset = CGSize(
                width: anchor.x - canvasPoint.x * newScale,
                height: anchor.y - canvasPoint.y * newScale
            )
            self.scale = newScale
            self.lastCommittedOffset = self.offset
            self.lastCommittedScale = self.scale
        }

        if animated {
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.85)) {
                apply()
            }
        } else {
            apply()
        }
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

    /// Zoom to fit only the selected nodes in the viewport.
    func zoomToSelection() {
        let selected = nodes.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }
        let padding: CGFloat = 120
        let minX = selected.map(\.position.x).min()! - padding
        let maxX = selected.map { $0.position.x + $0.width }.max()! + padding
        let minY = selected.map(\.position.y).min()! - padding
        let maxY = selected.map(\.position.y).max()! + padding

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

    // MARK: - 3D Detection & Parsing

    private static let scene3DKeywords = [
        "sphere", "cube", "box", "cylinder", "cone", "torus", "pyramid",
        "3d", "3D", "object", "shape", "render", "model", "capsule",
        "tube", "donut", "ring", "geometry", "mesh", "scene"
    ]

    static func is3DRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        let matchCount = scene3DKeywords.filter { lower.contains($0.lowercased()) }.count
        // Require at least one 3D keyword and the text should be short (a request, not a paragraph)
        return matchCount >= 1 && text.count < 200
    }

    /// Extract JSON from a response that may contain markdown code fences.
    static func parseSceneJSON(_ text: String) -> SceneDescription? {
        // Try to find ```json ... ``` block
        var jsonString = text
        if let start = text.range(of: "```json") ?? text.range(of: "```"),
           let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            jsonString = String(text[start.upperBound..<end.lowerBound])
        } else if let start = text.range(of: "{"),
                  let end = text.range(of: "}", options: .backwards) {
            jsonString = String(text[start.lowerBound...end.upperBound])
        }

        guard let data = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SceneDescription.self, from: data)
    }
}
