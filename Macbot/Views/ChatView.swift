import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool
    @State private var dragOver = false
    @State private var livePulse = false

    var body: some View {
        HStack(spacing: 0) {
            modeRail
            Divider()
            modeContent
        }
        .overlay {
            // Command palette — the universal keyboard-first nav surface.
            // One overlay serving all modes. Cmd+K toggles it.
            if viewModel.showPalette {
                CommandPalette(
                    viewModel: viewModel,
                    items: paletteItems,
                    onSelect: dispatchPaletteItem,
                    onDismiss: { viewModel.showPalette = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background(hiddenShortcutButtons)
        .background(MacbotDS.Colors.bg)
        .frame(minWidth: 700, minHeight: 520)
        .onAppear {
            inputFocused = true
            if viewModel.contentMode == .canvas {
                viewModel.refreshCanvasChats()
                viewModel.setupCanvas()
            }
            if viewModel.contentMode == .notebook {
                viewModel.setupNotebook()
            }
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch viewModel.contentMode {
        case .chat:
            chatModeLayout
        case .canvas:
            CanvasView(
                viewModel: viewModel.canvasViewModel,
                loadMessages: { viewModel.loadMessagesForCanvas(chatId: $0) },
                orchestrator: viewModel.canvasOrchestrator
            )
        case .notebook:
            NotebookView(viewModel: viewModel.notebookViewModel)
        }
    }

    /// Chat mode with an optional left-side list panel owned by the mode
    /// (not the app chrome). Cmd+\\ toggles visibility.
    private var chatModeLayout: some View {
        HStack(spacing: 0) {
            if viewModel.chatListVisible {
                chatListPanel
                    .frame(width: 240)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            chatContent
        }
    }

    // MARK: - Mode Rail (always visible, 44pt)

    /// The app-level navigation chrome. Always visible, always narrow.
    /// Contains only mode switching and the command palette launcher.
    /// Everything mode-specific lives inside each mode's own content view.
    private var modeRail: some View {
        VStack(spacing: MacbotDS.Space.md) {
            railButton(
                icon: "book.closed",
                mode: .notebook,
                help: "Notebook (⌘1)"
            )
            railButton(
                icon: "rectangle.on.rectangle.angled",
                mode: .canvas,
                help: "Canvas (⌘2)"
            )
            railButton(
                icon: "bubble.left.and.text.bubble.right",
                mode: .chat,
                help: "Chat (⌘3)"
            )

            Spacer()

            // Command palette launcher — the universal go-to.
            Button(action: { viewModel.togglePalette() }) {
                Image(systemName: "command")
                    .font(.system(size: 14))
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 32, height: 32)
                    .background(.fill.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Command Palette (⌘K)")
        }
        .padding(.vertical, MacbotDS.Space.md)
        .padding(.horizontal, 6)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(MacbotDS.Mat.chrome)
    }

    private func railButton(icon: String, mode: ContentMode, help: String) -> some View {
        let isActive = viewModel.contentMode == mode
        return Button(action: {
            withAnimation(Motion.snappy) {
                switchMode(to: mode)
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isActive ? MacbotDS.Colors.textPri : MacbotDS.Colors.textTer)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? AnyShapeStyle(MacbotDS.Colors.accent.opacity(0.18)) : AnyShapeStyle(.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isActive ? MacbotDS.Colors.accent.opacity(0.35) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Centralized mode switch — sets up the target mode's state before flipping.
    private func switchMode(to mode: ContentMode) {
        if mode == .canvas {
            viewModel.refreshCanvasChats()
            viewModel.setupCanvas()
        }
        if mode == .notebook {
            viewModel.setupNotebook()
        }
        viewModel.contentMode = mode
    }

    // MARK: - Hidden keyboard shortcuts

    /// Invisible buttons parked in a .background that carry the app-level
    /// keyboard shortcuts. `.keyboardShortcut` only works on buttons in the
    /// view tree, so this is the idiomatic SwiftUI pattern for cross-window
    /// shortcuts that shouldn't have a visible affordance.
    private var hiddenShortcutButtons: some View {
        Group {
            Button("") { withAnimation(Motion.snappy) { switchMode(to: .notebook) } }
                .keyboardShortcut(.init("1"), modifiers: .command)
            Button("") { withAnimation(Motion.snappy) { switchMode(to: .canvas) } }
                .keyboardShortcut(.init("2"), modifiers: .command)
            Button("") { withAnimation(Motion.snappy) { switchMode(to: .chat) } }
                .keyboardShortcut(.init("3"), modifiers: .command)
            Button("") { viewModel.togglePalette() }
                .keyboardShortcut(.init("K"), modifiers: .command)
            Button("") {
                withAnimation(Motion.snappy) { viewModel.toggleSecondaryPane() }
            }
            .keyboardShortcut(.init("\\"), modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .hidden()
    }

    // MARK: - Chat list panel (owned by chat mode)

    /// The chat list panel lives INSIDE chat mode now (not in the app rail),
    /// so it can own its own search, new-chat affordance, and list rendering
    /// without competing with other modes for sidebar real estate.
    private var chatListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with new-chat action
            HStack {
                Text("Chats")
                    .font(.caption2.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { viewModel.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textSec)
                }
                .buttonStyle(.plain)
                .help("New Chat (⌘N)")
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)

            // Search
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                TextField("Search chats...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .onChange(of: viewModel.searchQuery) { _, _ in viewModel.search() }
                if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(MacbotDS.Colors.textTer)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.sm)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.bottom, MacbotDS.Space.sm)

            Divider()

            if viewModel.isSearching {
                searchResultsList
            } else {
                chatList
            }

            Spacer(minLength: 0)
        }
        .background(MacbotDS.Mat.chrome)
    }

    // MARK: - Palette items & dispatch

    /// Build the palette's search corpus on demand. Includes every navigable
    /// object in the app plus the global action verbs.
    private var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = []

        // Actions — mode switches and create-new verbs.
        items.append(PaletteItem(
            id: "act:mode.notebook", title: "Switch to Notebook",
            subtitle: "⌘1", icon: "book.closed", category: .action,
            action: { withAnimation(Motion.snappy) { switchMode(to: .notebook) } }
        ))
        items.append(PaletteItem(
            id: "act:mode.canvas", title: "Switch to Canvas",
            subtitle: "⌘2", icon: "rectangle.on.rectangle.angled", category: .action,
            action: { withAnimation(Motion.snappy) { switchMode(to: .canvas) } }
        ))
        items.append(PaletteItem(
            id: "act:mode.chat", title: "Switch to Chat",
            subtitle: "⌘3", icon: "bubble.left.and.text.bubble.right", category: .action,
            action: { withAnimation(Motion.snappy) { switchMode(to: .chat) } }
        ))
        items.append(PaletteItem(
            id: "act:new.page", title: "New Page",
            subtitle: "In the current notebook", icon: "doc.badge.plus", category: .action,
            action: {
                switchMode(to: .notebook)
                viewModel.notebookViewModel.createPageInCurrentNotebook()
            }
        ))
        items.append(PaletteItem(
            id: "act:new.notebook", title: "New Notebook",
            subtitle: nil, icon: "book.closed", category: .action,
            action: {
                switchMode(to: .notebook)
                viewModel.notebookViewModel.createNotebook()
            }
        ))
        items.append(PaletteItem(
            id: "act:new.canvas", title: "New Canvas",
            subtitle: nil, icon: "plus.rectangle.on.rectangle", category: .action,
            action: {
                switchMode(to: .canvas)
                viewModel.canvasViewModel.createCanvas()
            }
        ))
        items.append(PaletteItem(
            id: "act:new.chat", title: "New Chat",
            subtitle: nil, icon: "square.and.pencil", category: .action,
            action: {
                switchMode(to: .chat)
                viewModel.newChat()
            }
        ))

        // Notebooks
        for nb in viewModel.notebookViewModel.notebooks {
            items.append(PaletteItem(
                id: "nb:\(nb.id)", title: nb.title,
                subtitle: "Notebook", icon: "book.closed", category: .notebook,
                action: {
                    switchMode(to: .notebook)
                    viewModel.notebookViewModel.selectNotebook(nb.id)
                }
            ))
        }

        // Pages — across every notebook, not just the current one.
        let notebooksById = Dictionary(
            uniqueKeysWithValues: viewModel.notebookViewModel.notebooks.map { ($0.id, $0.title) }
        )
        for page in viewModel.notebookViewModel.store.listAllPages() {
            let parent = notebooksById[page.notebookId] ?? "Notebook"
            items.append(PaletteItem(
                id: "page:\(page.id)",
                title: page.title.isEmpty ? "Untitled" : page.title,
                subtitle: parent,
                icon: "doc.text",
                category: .page,
                action: {
                    switchMode(to: .notebook)
                    viewModel.notebookViewModel.openPageAcrossNotebooks(pageId: page.id)
                }
            ))
        }

        // Canvases
        for canvas in viewModel.canvasViewModel.canvasList {
            items.append(PaletteItem(
                id: "canvas:\(canvas.id)",
                title: canvas.title,
                subtitle: "Canvas",
                icon: "rectangle.on.rectangle.angled",
                category: .canvas,
                action: {
                    switchMode(to: .canvas)
                    viewModel.canvasViewModel.switchCanvas(canvas.id)
                }
            ))
        }

        // Chats
        for chat in viewModel.chats {
            items.append(PaletteItem(
                id: "chat:\(chat.id)",
                title: chat.title,
                subtitle: "Chat",
                icon: "bubble.left.and.text.bubble.right",
                category: .chat,
                action: {
                    switchMode(to: .chat)
                    viewModel.selectChat(chat.id)
                }
            ))
        }

        return items
    }

    private func dispatchPaletteItem(_ item: PaletteItem) {
        viewModel.showPalette = false
        // Defer to next runloop so the palette teardown animation doesn't
        // fight the mode-switch animation.
        DispatchQueue.main.async { item.action() }
    }


    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.chats) { chat in
                    chatRow(chat)
                }
            }
            .padding(.vertical, MacbotDS.Space.xs)
        }
    }

    private func chatRow(_ chat: ChatRecord) -> some View {
        let isSelected = viewModel.currentChatId == chat.id

        return HStack(spacing: 0) {
            // Active indicator bar
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? MacbotDS.Colors.accent : .clear)
                .frame(width: 3)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
                Text(chat.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MacbotDS.Colors.textPri : MacbotDS.Colors.textSec)
                    .lineLimit(1)

                HStack {
                    Text(chat.lastMessage)
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .lineLimit(1)
                    Spacer()
                    Text(chat.updatedAt, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }
            }
            .padding(.horizontal, MacbotDS.Space.sm)
            .padding(.vertical, MacbotDS.Space.sm)
        }
        .padding(.leading, MacbotDS.Space.sm)
        .padding(.trailing, MacbotDS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { viewModel.selectChat(chat.id) }
        .draggable(ChatDragItem(chatId: chat.id, chatTitle: chat.title))
        .padding(.horizontal, MacbotDS.Space.xs)
        .contextMenu {
            Button("Delete", role: .destructive) { viewModel.deleteChat(chat.id) }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            if viewModel.searchResults.isEmpty {
                Text("No results")
                    .font(.caption)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { _, result in
                        Button(action: { viewModel.selectChat(result.message.chatId) }) {
                            VStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
                                Text(result.chatTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(MacbotDS.Colors.textPri)
                                    .lineLimit(1)
                                Text(result.message.content)
                                    .font(.caption2)
                                    .foregroundStyle(MacbotDS.Colors.textTer)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, MacbotDS.Space.md)
                            .padding(.vertical, MacbotDS.Space.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, MacbotDS.Space.sm)
                    }
                }
                .padding(.vertical, MacbotDS.Space.xs)
            }
        }
    }

    // MARK: - Chat Content

    private var chatContent: some View {
        ZStack(alignment: .bottom) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    if viewModel.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .containerRelativeFrame(.vertical) { height, _ in height }
                    } else {
                        LazyVStack(alignment: .leading, spacing: MacbotDS.Space.sm) {
                            ForEach(viewModel.messages) { msg in
                                let isLastAndStreaming = viewModel.isStreaming
                                    && msg.id == viewModel.messages.last?.id
                                    && msg.role == .assistant
                                MessageBubble(
                                    message: msg,
                                    onEdit: {
                                        viewModel.startEditing(message: msg)
                                        inputFocused = true
                                    },
                                    isStreaming: isLastAndStreaming
                                )
                                .id(msg.id)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 8)),
                                    removal: .opacity
                                ))
                            }

                            if let status = viewModel.currentStatus {
                                StatusIndicator(text: status)
                                    .padding(.horizontal, MacbotDS.Space.lg)
                                    .id("status")
                            }

                            if viewModel.isStreaming && viewModel.currentStatus == nil
                                && viewModel.messages.last?.role == .user {
                                typingIndicator.id("typing")
                            }

                            // Spacer for floating input
                            Color.clear.frame(height: 80)
                        }
                        .padding(.vertical, MacbotDS.Space.sm)
                    }
                }
                .onChange(of: viewModel.messages.count) {
                    withAnimation(Motion.snappy) {
                        if let lastId = viewModel.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            // Activity terminal + floating input
            VStack(spacing: MacbotDS.Space.sm) {
                ActivityTerminal()

                if !viewModel.pendingImages.isEmpty {
                    imagePreview
                }

                floatingInputBar
            }
            .padding(.horizontal, MacbotDS.Space.lg)
            .padding(.bottom, MacbotDS.Space.md)
        }
        .background(MacbotDS.Colors.bg)
        .onDrop(of: [.image, .fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if dragOver {
                RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous)
                    .stroke(MacbotDS.Colors.accent.opacity(0.5), lineWidth: 1.5)
                    .background(.ultraThinMaterial.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous))
                    .overlay {
                        VStack(spacing: MacbotDS.Space.sm) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 28, weight: .light))
                                .symbolRenderingMode(.hierarchical)
                            Text("Drop image to analyze")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(MacbotDS.Colors.accent.opacity(0.8))
                    }
                    .padding(MacbotDS.Space.xs)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        SmartGreeting()
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        TypingDots()
            .padding(.horizontal, MacbotDS.Space.lg)
            .padding(.vertical, MacbotDS.Space.sm)
    }

    // MARK: - Image Preview

    private var imagePreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MacbotDS.Space.sm) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { idx, data in
                    if let nsImage = NSImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous).stroke(MacbotDS.Colors.separator, lineWidth: 0.5))

                            Button(action: { viewModel.pendingImages.remove(at: idx) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .background(Circle().fill(MacbotDS.Mat.float))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.horizontal, MacbotDS.Space.xs)
            .padding(.bottom, MacbotDS.Space.sm)
        }
    }

    // MARK: - Floating Input Bar

    private var floatingInputBar: some View {
        VStack(spacing: MacbotDS.Space.sm) {
            // Editing indicator
            if viewModel.editingMessageId != nil {
                HStack(spacing: MacbotDS.Space.sm) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption)
                        .tint(MacbotDS.Colors.warning)
                        .foregroundStyle(MacbotDS.Colors.warning)
                    Text("Editing message — press Enter to resend")
                        .font(.caption2)
                        .foregroundStyle(MacbotDS.Colors.textSec)
                    Spacer()
                    Button("Cancel") {
                        viewModel.editingMessageId = nil
                        viewModel.inputText = ""
                    }
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, MacbotDS.Space.md)
                .padding(.vertical, MacbotDS.Space.sm)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous))
            }

            HStack(spacing: MacbotDS.Space.md) {
                Button(action: { pickImage() }) {
                    Image(systemName: "paperclip")
                        .font(.subheadline)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }
                .buttonStyle(.plain)
                .help("Attach image")

                TextField(
                    viewModel.editingMessageId != nil ? "Edit your message..." : "Message macbot...",
                    text: $viewModel.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(MacbotDS.Colors.textPri)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { sendMessage() }

                if viewModel.isStreaming {
                    // Stop button replaces send during streaming
                    Button(action: { viewModel.cancelStream() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(MacbotDS.Colors.warning)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    // Send / Resend button
                    Button(action: { sendMessage() }) {
                        Image(systemName: viewModel.editingMessageId != nil
                              ? "arrow.counterclockwise.circle.fill"
                              : "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? MacbotDS.Colors.accent : MacbotDS.Colors.textTer.opacity(0.3))
                    }
                    .disabled(!canSend)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.md)
            .background(MacbotDS.Mat.chrome)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(
                viewModel.editingMessageId != nil ? MacbotDS.Colors.warning.opacity(0.3) : MacbotDS.Colors.separator,
                lineWidth: 0.5
            ))
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
        }
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || !viewModel.pendingImages.isEmpty
    }

    // MARK: - Actions

    private func sendMessage() {
        if viewModel.editingMessageId != nil {
            viewModel.resendEdited()
        } else {
            viewModel.send()
        }
        inputFocused = true
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    viewModel.pendingImages.append(data)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage, let data = image.tiffRepresentation {
                        DispatchQueue.main.async {
                            viewModel.pendingImages.append(data)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Agent Badge

struct AgentBadge: View {
    let category: AgentCategory

    var body: some View {
        Text(category.displayName)
            .font(MacbotDS.Typo.detail)
            .foregroundStyle(.secondary)
            .padding(.horizontal, MacbotDS.Space.sm)
            .padding(.vertical, MacbotDS.Space.xs)
            .background(.fill.tertiary)
            .clipShape(Capsule())
    }
}

// MARK: - Animated Typing Dots

private struct TypingDots: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.primary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 0.9 : 0.25)
                    .scaleEffect(phase == i ? 1.15 : 1.0)
                    .animation(Motion.gentle, value: phase)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
