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

        // Detect if the request is for a 3D object
        let is3DRequest = Self.is3DRequest(userText)

        let fullPrompt: String
        if is3DRequest {
            fullPrompt = """
            The user wants a 3D object or scene. Respond ONLY with a JSON code block describing the scene. No other text.

            Use this exact format:
            ```json
            {
              "objects": [
                {
                  "shape": "sphere",
                  "size": 1.0,
                  "color": "#4499DD",
                  "metalness": 0.3,
                  "roughness": 0.4,
                  "position": {"x": 0, "y": 0, "z": 0}
                }
              ],
              "cameraDistance": 5.0,
              "showFloor": true
            }
            ```

            Available shapes: sphere, box, cylinder, cone, torus, plane, pyramid, capsule, tube, text3D
            For text3D, add "textContent": "the text"
            For box, add "chamfer": 0.05
            For torus, add "pipeRadius": 0.3
            Use "height" for cylinder, cone, capsule, tube, pyramid
            Use "rotation": {"x": 45, "y": 0, "z": 0} for rotation in degrees
            Use hex colors like "#FF6633"

            User request: \(userText)

            Respond with ONLY the JSON code block. Make it look good — use appealing colors, proper proportions, and a floor if appropriate.
            """
        } else {
            fullPrompt = """
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
        }

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
                            // Try to parse 3D scene from response
                            if is3DRequest, let scene = Self.parseSceneJSON(accumulated) {
                                self.nodes[idx].sceneData = scene
                                self.nodes[idx].width = 320
                            }
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

            // Final parse attempt for 3D
            if is3DRequest, let idx = self.nodes.firstIndex(where: { $0.id == resultNode.id }) {
                if let scene = Self.parseSceneJSON(accumulated) {
                    self.nodes[idx].sceneData = scene
                    self.nodes[idx].width = 320
                    // Clear the raw JSON text since we have the rendered scene
                    self.nodes[idx].text = ""
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
