import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI

struct CanvasView: View {
    @Bindable var viewModel: CanvasViewModel
    var loadMessages: ((String) -> [ChatMessageRecord])?
    var orchestrator: Orchestrator?
    @State private var aiPromptText = ""
    @State private var showAIBar = false
    @State private var isRenamingCanvas = false
    @State private var canvasRenameText = ""
    @FocusState private var canvasFocused: Bool

    /// O(1) node lookup for edge rendering — cached in ViewModel.
    private var nodeById: [UUID: CanvasNode] { viewModel._nodeById }

    private var viewCenter: CGPoint {
        CGPoint(x: viewModel.viewSize.width / 2, y: viewModel.viewSize.height / 2)
    }

    /// True when any text input is active — suppresses single-key shortcuts.
    private var isTextInputActive: Bool {
        viewModel.editingNodeId != nil
            || showAIBar
            || viewModel.showCanvasChat
            || viewModel.showSearch
            || isRenamingCanvas
            || viewModel.editingEdgeId != nil
            || viewModel.fullEditorNodeId != nil
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

                // Minimap
                if viewModel.showMinimap {
                    VStack {
                        HStack {
                            Spacer()
                            CanvasMinimap(
                                nodes: viewModel.nodes,
                                groups: viewModel.groups,
                                viewSize: viewModel.viewSize,
                                scale: viewModel.scale,
                                offset: viewModel.offset,
                                onNavigate: { newOffset in
                                    withAnimation(Motion.smooth) {
                                        viewModel.offset = newOffset
                                        viewModel.lastCommittedOffset = newOffset
                                    }
                                }
                            )
                            .padding(MacbotDS.Space.md)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // Box selection overlay
                if let rect = viewModel.selectionRect {
                    Rectangle()
                        .fill(MacbotDS.Colors.accent.opacity(0.08))
                        .overlay(
                            Rectangle()
                                .stroke(MacbotDS.Colors.accent.opacity(0.5), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
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
            .focusable()
            .focused($canvasFocused)
            .onAppear {
                canvasFocused = true
                CanvasBridge.shared.register(viewModel)
            }
            .onDisappear { CanvasBridge.shared.unregister(viewModel) }
            .onKeyPress(.delete) {
                guard !isTextInputActive else { return .ignored }
                withAnimation(Motion.snappy) { viewModel.deleteSelected() }
                return .handled
            }
            // Spacebar pan mode is handled by CanvasScrollHandler's NSEvent monitor
            // so it doesn't steal space key from text editors
            // Zoom shortcuts
            .onKeyPress(characters: CharacterSet(charactersIn: "=+")) { _ in
                guard !isTextInputActive else { return .ignored }
                withAnimation(Motion.snappy) {
                    viewModel.zoom(by: 1.25, anchor: viewCenter)
                }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "-")) { _ in
                guard !isTextInputActive else { return .ignored }
                withAnimation(Motion.snappy) {
                    viewModel.zoom(by: 0.8, anchor: viewCenter)
                }
                return .handled
            }
            // Backspace also deletes
            .onKeyPress(.init("\u{08}")) {
                guard !isTextInputActive else { return .ignored }
                withAnimation(Motion.snappy) { viewModel.deleteSelected() }
                return .handled
            }
            // Cmd shortcuts
            .onKeyPress(characters: CharacterSet(charactersIn: "012agcvxdzf")) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                if press.characters == "f" && press.modifiers.contains(.shift) {
                    withAnimation(Motion.snappy) { viewModel.showSearch = true }
                    return .handled
                }
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
                case "2":
                    withAnimation(Motion.smooth) { viewModel.zoomToSelection() }
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
                    if pasteImagesFromClipboard() {
                        return .handled
                    }
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
            // Quick add shortcuts (only when no text input is active)
            .onKeyPress(characters: CharacterSet(charactersIn: "ntre/m?")) { press in
                guard !isTextInputActive else { return .ignored }
                guard !press.modifiers.contains(.command) else { return .ignored }
                switch press.characters {
                case "n": quickAdd(color: .note); return .handled
                case "t": quickAdd(color: .task); return .handled
                case "r": quickAdd(color: .reference); return .handled
                case "e":
                    viewModel.edgeModeActive.toggle()
                    return .handled
                case "m":
                    withAnimation(Motion.snappy) { viewModel.showMinimap.toggle() }
                    return .handled
                case "/":
                    withAnimation(Motion.snappy) { showAIBar = true }
                    return .handled
                case "?":
                    withAnimation(Motion.snappy) { viewModel.showShortcutHelp.toggle() }
                    return .handled
                default: return .ignored
                }
            }
            // Tab cycles forward through nodes. Shift+Tab cycles the selected
            // card's color through the user-authored categories
            // (.note → .idea → .task) for quick keyboard-first tagging.
            .onKeyPress(.tab) {
                guard !isTextInputActive else { return .ignored }
                if NSEvent.modifierFlags.contains(.shift) {
                    viewModel.cycleSelectedColor()
                } else {
                    viewModel.navigateNode(forward: true)
                }
                return .handled
            }
            // Arrow keys for spatial navigation between nodes
            .onKeyPress(.upArrow) {
                guard !isTextInputActive else { return .ignored }
                viewModel.navigateDirection(.up)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard !isTextInputActive else { return .ignored }
                viewModel.navigateDirection(.down)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard !isTextInputActive else { return .ignored }
                viewModel.navigateDirection(.left)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard !isTextInputActive else { return .ignored }
                viewModel.navigateDirection(.right)
                return .handled
            }
            // Escape cascade: help → 3D → edge mode → AI bar → chat → deselect
            .onKeyPress(.escape) {
                if viewModel.showShortcutHelp {
                    withAnimation(Motion.snappy) { viewModel.showShortcutHelp = false }
                } else if viewModel.entered3DNodeId != nil {
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
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers, location in
                handleImageDrop(providers: providers, at: location)
                return true
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

            if viewModel.showInspector {
                Divider()
                inspectorPanel
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onChange(of: viewModel.selectedIds) { _, _ in
            viewModel.refreshRelatedNodes()
        }
        .onChange(of: viewModel.showInspector) { _, _ in
            viewModel.refreshRelatedNodes()
        }
        .overlay {
            if viewModel.showSearch {
                universalSearchOverlay
                    .transition(.opacity)
            }
        }
        .overlay {
            if viewModel.fullEditorNodeId != nil {
                fullWindowEditor
                    .transition(.opacity)
            }
        }
        .overlay {
            if viewModel.showShortcutHelp {
                shortcutHelpOverlay
                    .transition(.opacity)
            }
        }
        .overlay {
            if viewModel.showLanding {
                canvasLanding
                    .transition(.opacity)
            }
        }
        .task {
            viewModel.checkLanding()
        }
    }

    // MARK: - Universal Search

    @FocusState private var searchFocused: Bool

    private var universalSearchOverlay: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 80)

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: MacbotDS.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(MacbotDS.Colors.textTer)

                    TextField("Search all canvases...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .focused($searchFocused)
                        .onAppear { searchFocused = true }
                        .onChange(of: viewModel.searchQuery) { _, _ in viewModel.performSearch() }
                        .onSubmit {
                            if let first = viewModel.searchResults.first {
                                viewModel.navigateToSearchResult(first)
                            }
                        }
                        .onKeyPress(.escape) {
                            withAnimation(Motion.snappy) {
                                viewModel.showSearch = false
                                viewModel.searchQuery = ""
                                viewModel.searchResults = []
                            }
                            canvasFocused = true
                            return .handled
                        }

                    if !viewModel.searchQuery.isEmpty {
                        Button(action: {
                            viewModel.searchQuery = ""
                            viewModel.searchResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(MacbotDS.Colors.textTer)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MacbotDS.Space.md)
                .padding(.vertical, MacbotDS.Space.md)

                if !viewModel.searchResults.isEmpty {
                    Divider()

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { _, result in
                                Button(action: {
                                    viewModel.navigateToSearchResult(result)
                                    canvasFocused = true
                                }) {
                                    HStack(spacing: MacbotDS.Space.sm) {
                                        Circle()
                                            .fill((CanvasNode.NodeColor(rawValue: result.nodeColor) ?? .note).accentColor)
                                            .frame(width: 8, height: 8)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(result.nodeText)
                                                .font(.caption)
                                                .foregroundStyle(MacbotDS.Colors.textPri)
                                                .lineLimit(2)
                                            Text(result.canvasTitle)
                                                .font(.caption2)
                                                .foregroundStyle(MacbotDS.Colors.textTer)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, MacbotDS.Space.md)
                                    .padding(.vertical, MacbotDS.Space.sm)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                } else if !viewModel.searchQuery.isEmpty {
                    Divider()
                    Text("No results")
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .padding(MacbotDS.Space.md)
                }
            }
            .frame(width: 420)
            .background(MacbotDS.Mat.chrome)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous)
                    .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)

            Spacer()
        }
        .background(Color.black.opacity(0.3))
        .onTapGesture {
            withAnimation(Motion.snappy) {
                viewModel.showSearch = false
                viewModel.searchQuery = ""
                viewModel.searchResults = []
            }
            canvasFocused = true
        }
    }

    // MARK: - Full Window Viewer

    private var fullWindowEditor: some View {
        let node = viewModel.nodes.first(where: { $0.id == viewModel.fullEditorNodeId })
        let nodeColor: CanvasNode.NodeColor = node?.color ?? .note
        let accent: Color = nodeColor == .note
            ? MacbotDS.Colors.textSec
            : Color(hue: nodeColor.hue, saturation: 0.5, brightness: 0.85)
        let isEditing = viewModel.fullEditorIsEditing

        return VStack(spacing: 0) {
            // Title bar
            HStack(spacing: MacbotDS.Space.md) {
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)

                // Source badge
                if let node, node.isAINode {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                        Text("AI Generated")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(hue: 0.35, saturation: 0.5, brightness: 0.8))
                } else {
                    Text(nodeColor.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MacbotDS.Colors.textPri)
                }

                Spacer()

                if isEditing {
                    Text("\(viewModel.fullEditorText.count) characters")
                        .font(MacbotDS.Typo.detail)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .monospacedDigit()
                }

                // Edit / Read toggle
                Button(action: {
                    withAnimation(Motion.snappy) {
                        viewModel.fullEditorIsEditing.toggle()
                    }
                }) {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: isEditing ? "doc.richtext" : "pencil")
                            .font(.system(size: 10))
                        Text(isEditing ? "Preview" : "Edit")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .background(.fill.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: {
                    withAnimation(Motion.snappy) { viewModel.closeFullEditor(save: true) }
                }) {
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MacbotDS.Colors.accent)
                        .padding(.horizontal, MacbotDS.Space.md)
                        .padding(.vertical, MacbotDS.Space.xs)
                        .background(MacbotDS.Colors.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, MacbotDS.Space.xl)
            .padding(.vertical, MacbotDS.Space.md)

            Divider()

            if isEditing {
                // Edit mode — monospaced editor with live preview side by side
                HStack(spacing: 0) {
                    TextEditor(text: $viewModel.fullEditorText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .scrollContentBackground(.hidden)
                        .padding(MacbotDS.Space.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    ScrollView {
                        formattedContent
                            .padding(MacbotDS.Space.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Read mode — full-width beautifully formatted content
                ScrollView {
                    VStack(alignment: .leading, spacing: MacbotDS.Space.lg) {
                        formattedContent

                        // Images
                        if let images = node?.images, !images.isEmpty {
                            Divider()
                                .padding(.vertical, MacbotDS.Space.sm)
                            HStack(spacing: MacbotDS.Space.md) {
                                ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                                    if let nsImage = NSImage(data: data) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxHeight: 300)
                                            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, MacbotDS.Space.xl * 2)
                    .padding(.vertical, MacbotDS.Space.xl)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(MacbotDS.Colors.bg)
        .onKeyPress(.escape) {
            withAnimation(Motion.snappy) { viewModel.closeFullEditor(save: true) }
            return .handled
        }
    }

    private var formattedContent: some View {
        Markdown(viewModel.fullEditorText.isEmpty ? "*Empty note*" : viewModel.fullEditorText)
            .markdownTextStyle {
                FontSize(15)
                ForegroundColor(MacbotDS.Colors.textPri)
            }
            .markdownBlockStyle(\.heading1) { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(24)
                        FontWeight(.bold)
                        ForegroundColor(MacbotDS.Colors.textPri)
                    }
                    .padding(.bottom, MacbotDS.Space.xs)
            }
            .markdownBlockStyle(\.heading2) { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(20)
                        FontWeight(.semibold)
                        ForegroundColor(MacbotDS.Colors.textPri)
                    }
                    .padding(.bottom, MacbotDS.Space.xs)
            }
            .markdownBlockStyle(\.heading3) { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(17)
                        FontWeight(.semibold)
                        ForegroundColor(MacbotDS.Colors.textSec)
                    }
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                configuration.label
                    .padding(MacbotDS.Space.md)
                    .background(.fill.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                            .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
                    )
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                configuration.label
                    .padding(.leading, MacbotDS.Space.md)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(MacbotDS.Colors.accent.opacity(0.4))
                            .frame(width: 3)
                    }
            }
            .textSelection(.enabled)
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

    private func handleImageDrop(providers: [NSItemProvider], at location: CGPoint) {
        let canvasPoint = viewModel.viewToCanvas(location)
        // Check if we dropped onto an existing node
        let targetNode = hitTest(canvasPoint, excluding: nil)

        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage,
                          let data = image.tiffRepresentation else { return }
                    Task { @MainActor in
                        if let target = targetNode {
                            self.viewModel.addImages(to: target.id, images: [data])
                        } else {
                            self.viewModel.addImagesToSelection([data], at: canvasPoint)
                        }
                    }
                }
            }
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
                    onZoom: { factor, anchor, animated in
                        viewModel.zoom(by: factor, anchor: anchor, animated: animated)
                    },
                    onSpacebarChanged: { down in
                        viewModel.isSpacebarDown = down
                    },
                    onMouseMoved: { point in
                        if viewModel.pendingEdgeFromId != nil {
                            viewModel.pendingEdgeEnd = point
                        }
                    },
                    isSpacebarDown: viewModel.isSpacebarDown,
                    isEdgeModeActive: viewModel.edgeModeActive || viewModel.pendingEdgeFromId != nil
                )
            }
            .contentShape(Rectangle())
            // Spacebar + drag for pan, otherwise box selection
            .gesture(spacebarPanOrBoxSelectGesture)
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
                canvasFocused = true
            }
            .onAppear { viewModel.viewSize = geo.size }
            .onChange(of: geo.size) { _, newSize in viewModel.viewSize = newSize }
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let baseSpacing: CGFloat = 40
        let spacing = baseSpacing * viewModel.scale
        guard spacing > 3 else { return }

        let majorEvery = 5 // every 5th dot is a major dot
        let ox = viewModel.offset.width.truncatingRemainder(dividingBy: spacing)
        let oy = viewModel.offset.height.truncatingRemainder(dividingBy: spacing)

        // Grid indices for major dot detection
        let startCol = Int(floor(-viewModel.offset.width / spacing))
        let startRow = Int(floor(-viewModel.offset.height / spacing))

        let minorRadius: CGFloat = max(1.0, 1.0 * viewModel.scale)
        let majorRadius: CGFloat = max(2.0, 2.0 * viewModel.scale)
        let minorColor = Color(nsColor: .separatorColor).opacity(0.35)
        let majorColor = Color(nsColor: .separatorColor).opacity(0.7)

        // Fade out minor dots at low zoom for cleaner look
        let showMinor = spacing > 6

        var col = 0
        var x = ox
        while x < size.width {
            var row = 0
            var y = oy
            while y < size.height {
                let isMajor = (startCol + col) % majorEvery == 0 && (startRow + row) % majorEvery == 0
                if isMajor || showMinor {
                    let r = isMajor ? majorRadius : minorRadius
                    let c = isMajor ? majorColor : minorColor
                    ctx.fill(
                        Path(ellipseIn: CGRect(
                            x: x - r / 2, y: y - r / 2,
                            width: r, height: r
                        )),
                        with: .color(c)
                    )
                }
                y += spacing
                row += 1
            }
            x += spacing
            col += 1
        }
    }

    // MARK: - Gestures

    /// Spacebar + drag for pan, otherwise box selection.
    private var spacebarPanOrBoxSelectGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if viewModel.isSpacebarDown {
                    // Pan mode
                    viewModel.selectionRect = nil
                    viewModel.selectionOrigin = nil
                    viewModel.offset = CGSize(
                        width: viewModel.lastCommittedOffset.width + value.translation.width,
                        height: viewModel.lastCommittedOffset.height + value.translation.height
                    )
                } else {
                    // Box selection mode
                    if viewModel.selectionOrigin == nil {
                        viewModel.beginBoxSelection(at: value.startLocation)
                    }
                    viewModel.updateBoxSelection(to: value.location)
                }
            }
            .onEnded { _ in
                if viewModel.isSpacebarDown {
                    viewModel.lastCommittedOffset = viewModel.offset
                } else if viewModel.selectionRect != nil {
                    viewModel.commitBoxSelection()
                }
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
            .scaleEffect(viewModel.scale)
            .position(viewModel.canvasToView(CGPoint(
                x: group.position.x + group.size.width / 2,
                y: group.position.y + group.size.height / 2
            )))
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
                guard let from = nodeById[edge.fromId],
                      let to = nodeById[edge.toId] else { continue }

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
            if let from = nodeById[edge.fromId],
               let to = nodeById[edge.toId] {
                let p1 = viewModel.canvasToView(from.position)
                let p2 = viewModel.canvasToView(to.position)
                let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

                if viewModel.editingEdgeId == edge.id {
                    EdgeLabelEditor(
                        text: $viewModel.editingEdgeLabel,
                        onCommit: { viewModel.updateEdgeLabel(id: edge.id, label: viewModel.editingEdgeLabel) }
                    )
                    .scaleEffect(viewModel.scale)
                    .position(midpoint)
                } else {
                    edgeLabelView(edge: edge)
                        .scaleEffect(viewModel.scale)
                        .position(midpoint)
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
                  let from = nodeById[fromId] else { return }

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

    /// Only nodes whose canvas position projects into the visible viewport
    /// (with a generous margin) are rendered. Prevents SwiftUI from diffing
    /// and laying out hundreds of off-screen nodes during pan/zoom.
    private var visibleNodes: [CanvasNode] {
        let margin: CGFloat = 400 // render slightly outside viewport for smooth scrolling
        let vw = viewModel.viewSize.width
        let vh = viewModel.viewSize.height
        return viewModel.nodes.filter { node in
            let vp = viewModel.canvasToView(node.position)
            return vp.x > -margin && vp.x < vw + margin
                && vp.y > -margin && vp.y < vh + margin
        }
    }

    private var nodesLayer: some View {
        let isCreatingEdge = viewModel.pendingEdgeFromId != nil

        return ForEach(visibleNodes) { node in
            let isHovered = viewModel.hoveredNodeId == node.id
            let isDragging = viewModel.draggingNodeId == node.id
            let isSelected = viewModel.selectedIds.contains(node.id)
            let isEdgeTarget = isCreatingEdge
                && viewModel.pendingEdgeFromId != node.id
                && isHovered

            CanvasNodeView(
                node: node,
                isSelected: isSelected,
                isEditing: viewModel.editingNodeId == node.id,
                isAIStreaming: viewModel.aiStreamingNodeId == node.id
                    || viewModel.activeCouncilNodeIds.contains(node.id),
                isProcessingSource: viewModel.processingSourceIds.contains(node.id),
                isEntered3D: viewModel.entered3DNodeId == node.id,
                isHovered: isHovered,
                scale: viewModel.scale,
                onTextChange: { viewModel.updateText(id: node.id, text: $0) },
                onCommitEdit: { viewModel.editingNodeId = nil },
                onStartEdge: { viewModel.pendingEdgeFromId = node.id },
                onExecute: {
                    viewModel.select(node.id)
                    executeSelectedNodes()
                },
                onWidgetExecute: {
                    guard let orchestrator else { return }
                    viewModel.executeWidget(nodeId: node.id, orchestrator: orchestrator)
                },
                onWidgetEdit: {
                    viewModel.widgetEditPrompt(nodeId: node.id)
                },
                onWidgetRerun: {
                    guard let orchestrator else { return }
                    viewModel.widgetRerun(nodeId: node.id, orchestrator: orchestrator)
                },
                onWidgetExpand: {
                    viewModel.select(node.id)
                    // Restore original prompt before expanding
                    if let idx = viewModel.nodes.firstIndex(where: { $0.id == node.id }),
                       let original = viewModel.nodes[idx].originalPrompt {
                        viewModel.nodes[idx].text = original
                        viewModel.nodes[idx].widgetState = .idle
                        viewModel.nodes[idx].originalPrompt = nil
                    }
                    executeSelectedNodes()
                },
                onEnterEdit: {
                    viewModel.select(node.id)
                    viewModel.editingNodeId = node.id
                }
            )
            .scaleEffect(viewModel.scale * (isDragging ? 1.03 : isHovered ? 1.01 : 1.0))
            .position(viewModel.canvasToView(node.position))
            .shadow(
                color: isDragging ? .black.opacity(0.18) :
                       isEdgeTarget ? MacbotDS.Colors.accent.opacity(0.3) :
                       isHovered && !isSelected ? .black.opacity(0.10) : .clear,
                radius: isDragging ? 20 : isEdgeTarget ? 16 : 12,
                y: isDragging ? 8 : 4
            )
            .overlay(
                // Edge target glow ring
                isEdgeTarget ?
                    RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous)
                        .stroke(MacbotDS.Colors.accent.opacity(0.6), lineWidth: 2)
                        .allowsHitTesting(false)
                    : nil
            )
            .animation(Motion.snappy, value: isDragging)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85).combined(with: .opacity),
                removal: .scale(scale: 0.9).combined(with: .opacity)
            ))
            .onHover { hovering in
                viewModel.hoveredNodeId = hovering ? node.id : nil
            }
            .onTapGesture(count: 2) {
                viewModel.select(node.id)
                if node.sceneData != nil {
                    viewModel.enter3DNode(id: node.id)
                } else {
                    withAnimation(Motion.snappy) {
                        viewModel.openFullEditor(nodeId: node.id)
                    }
                }
            }
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

        Button("Open") {
            withAnimation(Motion.snappy) { viewModel.openFullEditor(nodeId: node.id) }
        }

        Button("Edit") {
            withAnimation(Motion.snappy) { viewModel.openFullEditor(nodeId: node.id, editing: true) }
        }

        Button("Chat from here") {
            viewModel.startChat(from: node.id)
        }

        Button("Add Images...") {
            viewModel.pickAndAddImages(to: node.id)
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

        Menu("Orchestrate") {
            Button("Decompose into Cards") {
                viewModel.select(node.id)
                invokeOrchestration(action: .decompose)
            }
            Button("Research & Map") {
                viewModel.select(node.id)
                invokeOrchestration(action: .researchMap)
            }
            Button("Branch Ideas") {
                viewModel.select(node.id)
                invokeOrchestration(action: .branchIdeas)
            }
            Button("Plan Steps") {
                viewModel.select(node.id)
                invokeOrchestration(action: .planSteps)
            }
            Button("Fact Sheet") {
                viewModel.select(node.id)
                invokeOrchestration(action: .factSheet)
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

        // Set Color — absorbs what used to be in the contextual selection bar.
        // "Cycle Color" stays for keyboard-adjacent quick toggling; the nested
        // Menu lets mouse users pick a specific color without guessing.
        Menu("Set Color") {
            ForEach(CanvasNode.NodeColor.allCases, id: \.self) { color in
                Button(color.rawValue.capitalized) {
                    if !viewModel.selectedIds.contains(node.id) {
                        viewModel.select(node.id)
                    }
                    viewModel.setColor(color)
                }
            }
        }
        Button("Cycle Color (⇧⇥)") { viewModel.cycleColor(id: node.id) }

        // Resize — width presets, formerly in the contextual bar.
        Menu("Resize") {
            Button("Small (160)")  { ensureSelected(node); viewModel.resizeSelected(width: 160) }
            Button("Medium (220)") { ensureSelected(node); viewModel.resizeSelected(width: 220) }
            Button("Large (300)")  { ensureSelected(node); viewModel.resizeSelected(width: 300) }
            Button("Wide (400)")   { ensureSelected(node); viewModel.resizeSelected(width: 400) }
        }

        // Align / Distribute — only meaningful with 2+ selected.
        if viewModel.selectedIds.count >= 2 {
            Menu("Align") {
                Button("Left")   { viewModel.alignSelected(.left) }
                Button("Center") { viewModel.alignSelected(.centerH) }
                Button("Right")  { viewModel.alignSelected(.right) }
                Divider()
                Button("Top")    { viewModel.alignSelected(.top) }
                Button("Middle") { viewModel.alignSelected(.centerV) }
                Button("Bottom") { viewModel.alignSelected(.bottom) }
                if viewModel.selectedIds.count >= 3 {
                    Divider()
                    Button("Distribute Horizontally") {
                        viewModel.distributeSelected(axis: .horizontal)
                    }
                    Button("Distribute Vertically") {
                        viewModel.distributeSelected(axis: .vertical)
                    }
                }
            }
            Button("Group Selected (⌘G)") { viewModel.groupFromSelection() }
        }

        Button("Duplicate (⌘D)") {
            ensureSelected(node)
            viewModel.duplicateSelected()
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

    /// Select the node if it isn't already part of the current selection.
    /// Used by context-menu actions so right-clicking a non-selected node
    /// acts on that node rather than on a stale selection elsewhere.
    private func ensureSelected(_ node: CanvasNode) {
        if !viewModel.selectedIds.contains(node.id) {
            viewModel.select(node.id)
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

    private func invokeOrchestration(action: CanvasViewModel.OrchestrationAction) {
        guard let orchestrator else { return }
        viewModel.orchestrateAI(action: action, orchestrator: orchestrator)
    }

    private func nodeDragGesture(node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Don't move node when inside 3D interaction mode
                guard viewModel.entered3DNodeId != node.id else { return }
                let dist = hypot(value.translation.width, value.translation.height)
                if dist > 4 {
                    // Only move the card if it was already selected. Dragging
                    // on an unselected card used to start a move immediately,
                    // which made canvas-panning over cards impossible — the
                    // card would get grabbed instead. Requiring selection
                    // first gives a deliberate "I mean to move this" step.
                    guard viewModel.selectedIds.contains(node.id) else { return }
                    if viewModel.draggingNodeId == nil {
                        viewModel.draggingNodeId = node.id
                        viewModel.beginDrag(anchorId: node.id)
                    }
                    let newCanvas = viewModel.viewToCanvas(value.location)
                    let snap = NSEvent.modifierFlags.contains(.shift)
                    viewModel.moveSelectedNodes(anchorId: node.id, to: newCanvas, snap: snap)
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
                        canvasFocused = true
                    }
                } else if viewModel.draggingNodeId == node.id {
                    // A move actually happened — commit it. If the drag was on
                    // an unselected card we never called beginDrag, so skip.
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
        // Single-bar model: the contextual selection bar was dissolved because
        // its contents were either globally redundant (undo/redo/delete/
        // duplicate have keyboard shortcuts everywhere) or only accidentally
        // selection-dependent. Selection-specific actions (color / resize /
        // align) now live on the node's right-click context menu, which is
        // the macOS-native discovery path and doesn't introduce a second
        // floating chrome element competing with the primary toolbar.
        primaryToolbar
            .padding(.bottom, MacbotDS.Space.md)
    }

    private var primaryToolbar: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            // Creation cluster
            quickAddButton
            toolbarToggle("point.forward.to.point.capsulepath.fill",
                          help: "Edge Mode (E)",
                          isActive: viewModel.edgeModeActive) {
                viewModel.edgeModeActive.toggle()
            }

            Divider().frame(height: 18)

            // Primary action — Execute. Labeled and accent-colored so the
            // commit-work verb reads as the loudest pixel.
            executePrimaryButton

            // Secondary actions — AI prompt, chat browser.
            toolbarButton("sparkles", help: "Ask AI (/)") {
                withAnimation(Motion.snappy) { showAIBar.toggle() }
            }
            .disabled(viewModel.selectedIds.isEmpty)

            toolbarButton("bubble.left.and.bubble.right", help: "Chat Browser") {
                withAnimation(Motion.snappy) { viewModel.showChatBrowser.toggle() }
            }

            Divider().frame(height: 18)

            // View cluster — zoom, fit, minimap grouped in a sub-capsule so
            // they visually read as "one control for viewing" rather than
            // four independent controls.
            viewCluster

            // Trailing inspector toggle — sits outside the view cluster
            // because it opens a side panel, not a viewport change.
            toolbarToggle("sparkle.magnifyingglass", help: "Related Nodes",
                          isActive: viewModel.showInspector) {
                withAnimation(Motion.snappy) { viewModel.showInspector.toggle() }
            }
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(MacbotDS.Mat.chrome)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(MacbotDS.Colors.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    private var executePrimaryButton: some View {
        Button(action: executeSelectedNodes) {
            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Run")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MacbotDS.Colors.accent)
            .padding(.horizontal, MacbotDS.Space.sm + 2)
            .padding(.vertical, 5)
            .background(MacbotDS.Colors.accent.opacity(0.18))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(MacbotDS.Colors.accent.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Execute selected nodes (⌘↩)")
        .disabled(viewModel.selectedIds.isEmpty || viewModel.isProcessingAI)
        .opacity((viewModel.selectedIds.isEmpty || viewModel.isProcessingAI) ? 0.5 : 1)
    }

    private var viewCluster: some View {
        HStack(spacing: 2) {
            Button(action: {
                withAnimation(Motion.snappy) { viewModel.zoom(by: 0.8, anchor: viewCenter) }
            }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Zoom Out (-)")

            Button(action: {
                withAnimation(Motion.smooth) {
                    viewModel.offset = .zero
                    viewModel.lastCommittedOffset = .zero
                    viewModel.scale = 1.0
                    viewModel.lastCommittedScale = 1.0
                }
            }) {
                Text("\(Int(viewModel.scale * 100))%")
                    .font(MacbotDS.Typo.detail.monospacedDigit())
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 36, height: 22)
            }
            .buttonStyle(.plain)
            .help("Reset zoom (⌘0)")

            Button(action: {
                withAnimation(Motion.snappy) { viewModel.zoom(by: 1.25, anchor: viewCenter) }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Zoom In (+)")

            Rectangle()
                .fill(MacbotDS.Colors.separator.opacity(0.5))
                .frame(width: 0.5, height: 14)

            Button(action: { withAnimation(Motion.smooth) { viewModel.zoomToFit() } }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Zoom to Fit (⌘1)")

            Button(action: {
                withAnimation(Motion.snappy) { viewModel.showMinimap.toggle() }
            }) {
                Image(systemName: "map")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(viewModel.showMinimap ? MacbotDS.Colors.accent : MacbotDS.Colors.textSec)
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .help("Minimap (M)")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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

    /// Check the system clipboard for images. If found, add them to the selected node
    /// or create a new node. Returns true if images were handled.
    private func pasteImagesFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        guard let types = pb.types else { return false }

        // Check for image data on the clipboard
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes where types.contains(type) {
            if let data = pb.data(forType: type) {
                let center = viewModel.viewToCanvas(viewCenter)
                viewModel.addImagesToSelection([data], at: center)
                return true
            }
        }

        // Check for file URLs that are images
        if types.contains(.fileURL),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [
               .urlReadingContentsConformToTypes: ["public.image"]
           ]) as? [URL] {
            let imageData: [Data] = urls.compactMap { url in
                guard let nsImage = NSImage(contentsOf: url) else { return nil }
                return nsImage.tiffRepresentation
            }
            if !imageData.isEmpty {
                let center = viewModel.viewToCanvas(viewCenter)
                viewModel.addImagesToSelection(imageData, at: center)
                return true
            }
        }

        return false
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

    @FocusState private var canvasRenameFocused: Bool

    private var canvasPickerButton: some View {
        Group {
            if isRenamingCanvas {
                HStack(spacing: MacbotDS.Space.xs) {
                    TextField("Canvas name", text: $canvasRenameText)
                        .textFieldStyle(.plain)
                        .font(MacbotDS.Typo.detail)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                        .frame(width: 120)
                        .focused($canvasRenameFocused)
                        .onAppear { canvasRenameFocused = true }
                        .onSubmit {
                            if let id = viewModel.currentCanvasId, !canvasRenameText.isEmpty {
                                viewModel.renameCanvas(id, title: canvasRenameText)
                            }
                            isRenamingCanvas = false
                            canvasFocused = true
                        }
                        .onKeyPress(.escape) {
                            isRenamingCanvas = false
                            canvasFocused = true
                            return .handled
                        }
                }
            } else {
                let title = viewModel.canvasList.first(where: { $0.id == viewModel.currentCanvasId })?.title ?? "Canvas"
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
                    if viewModel.canvasList.count > 1, let id = viewModel.currentCanvasId {
                        Button("Delete Canvas", role: .destructive) {
                            viewModel.deleteCanvas(id)
                        }
                    }
                    Divider()
                    Button("Export as Markdown...") {
                        viewModel.exportMarkdownToFile()
                    }
                } label: {
                    HStack(spacing: MacbotDS.Space.xs) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.caption2)
                        Text(title)
                            .font(MacbotDS.Typo.detail)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(MacbotDS.Colors.textSec)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 160)
                .onTapGesture(count: 2) {
                    canvasRenameText = title
                    isRenamingCanvas = true
                }
            }
        }
    }

    // MARK: - Inspector Panel (Related Nodes)

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.accent)
                Text("Related")
                    .font(MacbotDS.Typo.heading)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                Spacer()
                Button(action: {
                    withAnimation(Motion.snappy) { viewModel.showInspector = false }
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
                    if viewModel.selectedIds.count != 1 {
                        inspectorEmptyState(
                            icon: "cursorarrow.rays",
                            message: "Select a node to see related notes."
                        )
                    } else if viewModel.relatedNodes.isEmpty {
                        inspectorEmptyState(
                            icon: "doc.text.magnifyingglass",
                            message: "No related nodes yet. Edit the selected node or add more notes — embeddings catch up asynchronously."
                        )
                    } else {
                        ForEach(viewModel.relatedNodes, id: \.nodeId) { result in
                            relatedNodeRow(result)
                        }
                    }
                }
                .padding(.vertical, MacbotDS.Space.xs)
            }
        }
        .background(MacbotDS.Mat.chrome)
    }

    private func inspectorEmptyState(icon: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: MacbotDS.Space.sm) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(MacbotDS.Colors.textTer)
            Text(message)
                .font(.caption)
                .foregroundStyle(MacbotDS.Colors.textTer)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.lg)
    }

    private func relatedNodeRow(_ result: CanvasStore.SearchResult) -> some View {
        Button {
            viewModel.navigateToSearchResult(result)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(nodeColor(from: result.nodeColor))
                        .frame(width: 6, height: 6)
                    Text(result.canvasTitle)
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .lineLimit(1)
                    Spacer()
                    if let sim = result.similarity {
                        Text("\(Int(sim * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(MacbotDS.Colors.textTer)
                    }
                }
                Text(result.nodeText.isEmpty ? "(empty)" : result.nodeText)
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nodeColor(from raw: String) -> Color {
        (CanvasNode.NodeColor(rawValue: raw) ?? .note).accentColor
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

    // MARK: - Canvas Landing

    @State private var landingHintsVisible: Bool = false
    @State private var landingTitleVisible: Bool = false
    @State private var landingCaptureText: String = ""
    @FocusState private var landingInputFocused: Bool

    /// Empty-canvas landing — chat-inspired: one quiet greeting, one focused
    /// capture input. The input's chrome mirrors the chat composer exactly
    /// (Material, Capsule, thin stroke, subtle shadow) so the canvas
    /// "starts like a conversation." Typing and pressing Return drops the
    /// first note at canvas center and dismisses the landing.
    private var canvasLanding: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: MacbotDS.Space.xl) {
                Text("What's on your mind?")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(MacbotDS.Colors.textPri.opacity(0.85))
                    .opacity(landingTitleVisible ? 1 : 0)
                    .offset(y: landingTitleVisible ? 0 : 6)

                landingCaptureInput
                    .frame(maxWidth: 560)
                    .opacity(landingTitleVisible ? 1 : 0)
                    .offset(y: landingTitleVisible ? 0 : 10)

                HStack(spacing: MacbotDS.Space.md) {
                    captureHint(key: "↩", label: "Place on canvas")
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textTer.opacity(0.5))
                    captureHint(key: "⌘K", label: "Open anything")
                }
                .opacity(landingHintsVisible ? 1 : 0)
            }
            .padding(.horizontal, MacbotDS.Space.xl)

            Spacer()

            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                Text("Everything runs locally on this Mac")
                    .font(.system(size: 11))
            }
            .foregroundStyle(MacbotDS.Colors.textTer.opacity(0.45))
            .padding(.bottom, MacbotDS.Space.xl)
            .opacity(landingHintsVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacbotDS.Colors.bg)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { landingTitleVisible = true }
            withAnimation(.easeOut(duration: 0.55).delay(0.25)) { landingHintsVisible = true }
        }
    }

    private var landingCaptureInput: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: "sparkles")
                .font(.callout)
                .foregroundStyle(MacbotDS.Colors.textTer)

            TextField("Capture a thought…", text: $landingCaptureText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(MacbotDS.Colors.textPri)
                .lineLimit(1...6)
                .focused($landingInputFocused)
                .onSubmit(submitLandingCapture)
                .onKeyPress(.return) {
                    // `onSubmit` handles plain Return; intercept Shift+Return
                    // so the multi-line axis grows instead of submitting.
                    if NSEvent.modifierFlags.contains(.shift) { return .ignored }
                    submitLandingCapture()
                    return .handled
                }

            if !landingCaptureText.isEmpty {
                Button(action: submitLandingCapture) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(MacbotDS.Colors.accent)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.md)
        .background(MacbotDS.Mat.chrome)
        .clipShape(Capsule())
        .overlay(
            Capsule().stroke(MacbotDS.Colors.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        .onTapGesture { landingInputFocused = true }
        .onAppear {
            // Small delay so the entrance animation finishes before focus
            // claims the caret — avoids a jarring flicker on first render.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                landingInputFocused = true
            }
        }
    }

    private func captureHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.weight(.medium).monospaced())
                .foregroundStyle(MacbotDS.Colors.textSec)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(label)
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.textTer)
        }
    }

    private func submitLandingCapture() {
        let trimmed = landingCaptureText.trimmingCharacters(in: .whitespacesAndNewlines)
        let center = viewModel.viewToCanvas(viewCenter)
        if trimmed.isEmpty {
            // Empty submit just dismisses and opens a blank note for editing.
            viewModel.dismissLanding()
            withAnimation(Motion.snappy) { viewModel.addNode(at: center, color: .note) }
        } else {
            viewModel.dismissLanding()
            withAnimation(Motion.snappy) {
                viewModel.addNote(text: trimmed, at: center, color: .note)
            }
            landingCaptureText = ""
        }
    }

    // MARK: - Shortcut Help Overlay

    private var shortcutHelpOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture {
                    withAnimation(Motion.snappy) { viewModel.showShortcutHelp = false }
                }

            VStack(alignment: .leading, spacing: MacbotDS.Space.lg) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(MacbotDS.Typo.title)
                        .foregroundStyle(MacbotDS.Colors.textPri)
                    Spacer()
                    Button(action: {
                        withAnimation(Motion.snappy) { viewModel.showShortcutHelp = false }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(MacbotDS.Colors.textTer)
                    }
                    .buttonStyle(.plain)
                }

                HStack(alignment: .top, spacing: MacbotDS.Space.xl) {
                    shortcutColumn("Navigation", shortcuts: [
                        ("Space + Drag", "Pan canvas"),
                        ("Scroll", "Pan (trackpad & mouse)"),
                        ("Pinch / Cmd+Scroll", "Zoom toward cursor"),
                        ("+ / -", "Zoom in / out"),
                        ("Cmd+0", "Reset zoom"),
                        ("Cmd+1", "Zoom to fit all"),
                        ("Cmd+2", "Zoom to selection"),
                        ("Tab / Shift+Tab", "Cycle nodes"),
                        ("Arrow Keys", "Navigate to nearest node"),
                        ("M", "Toggle minimap"),
                    ])

                    shortcutColumn("Editing", shortcuts: [
                        ("N", "New note"),
                        ("T", "New task"),
                        ("R", "New reference"),
                        ("Double-click", "Edit node / Add node"),
                        ("Delete / Backspace", "Delete selected"),
                        ("Cmd+D", "Duplicate"),
                        ("Cmd+C / X / V", "Copy / Cut / Paste"),
                        ("Cmd+Z / Shift+Z", "Undo / Redo"),
                        ("Shift + Drag", "Snap to grid"),
                    ])

                    shortcutColumn("Selection & Tools", shortcuts: [
                        ("Click", "Select node"),
                        ("Cmd/Shift + Click", "Multi-select"),
                        ("Drag empty area", "Box select"),
                        ("Cmd+A", "Select all"),
                        ("E", "Toggle edge mode"),
                        ("Cmd+G", "Group selected"),
                        ("/", "AI prompt"),
                        ("Cmd+Return", "Execute selected"),
                        ("Cmd+Shift+F", "Search all canvases"),
                        ("Escape", "Dismiss / Deselect"),
                        ("?", "This help"),
                    ])
                }
            }
            .padding(MacbotDS.Space.xl)
            .frame(maxWidth: 720)
            .background(MacbotDS.Mat.chrome)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous)
                    .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        }
    }

    private func shortcutColumn(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: MacbotDS.Space.sm) {
            Text(title)
                .font(MacbotDS.Typo.heading)
                .foregroundStyle(MacbotDS.Colors.textPri)
                .padding(.bottom, 2)

            ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: MacbotDS.Space.sm) {
                    Text(pair.0)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(MacbotDS.Colors.accent)
                        .frame(minWidth: 100, alignment: .trailing)
                    Text(pair.1)
                        .font(.system(size: 11))
                        .foregroundStyle(MacbotDS.Colors.textSec)
                }
            }
        }
    }
}

// EdgeLabelEditor, CanvasGroupFrame, and CanvasNodeView have been
// extracted to Macbot/Views/Canvas/
