import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool
    @State private var dragOver = false
    @State private var livePulse = false
    @State private var sidebarCollapsed = true

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                // Notebook mode gets a narrow icon rail so it doesn't
                // double-show the notebook list (NotebookView's own
                // notebooks pane is authoritative). Chat and Canvas keep
                // the full 220pt sidebar.
                if viewModel.contentMode == .notebook {
                    railSidebar
                        .frame(width: 52)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    sidebar
                        .frame(width: 220)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Divider()
            }

            switch viewModel.contentMode {
            case .chat:
                chatContent
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
        .overlay(alignment: .topLeading) {
            if sidebarCollapsed {
                if viewModel.contentMode == .notebook {
                    // Notebook has content flush at the top-left (notebooks
                    // pane). Show only the tiny sidebar-toggle so the pill
                    // doesn't cover the list. Mode cycle stays reachable via
                    // ⌘⇧J and the hidden keyboard button below.
                    Button(action: {
                        withAnimation(Motion.snappy) { sidebarCollapsed = false }
                    }) {
                        Image(systemName: "sidebar.left")
                            .font(.caption)
                            .foregroundStyle(MacbotDS.Colors.textSec)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(MacbotDS.Mat.chrome)
                            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                                    .stroke(MacbotDS.Colors.separator.opacity(0.3), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Show sidebar")
                    .padding(MacbotDS.Space.sm)
                    .transition(.opacity)
                } else {
                    // Canvas/Chat have empty space at top-left. Show the full
                    // pill: sidebar-expand + quick mode cycle.
                    HStack(spacing: MacbotDS.Space.xs) {
                        Button(action: {
                            withAnimation(Motion.snappy) { sidebarCollapsed = false }
                        }) {
                            Image(systemName: "sidebar.left")
                                .font(.caption)
                                .foregroundStyle(MacbotDS.Colors.textSec)
                        }
                        .buttonStyle(.plain)
                        .help("Show sidebar")

                        Divider().frame(height: 14)

                        Button(action: cycleContentMode) {
                            HStack(spacing: MacbotDS.Space.xs) {
                                Image(systemName: modeIcon(for: nextMode))
                                    .font(.system(size: 10))
                                Text(modeLabel(for: nextMode))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(MacbotDS.Colors.textSec)
                        }
                        .buttonStyle(.plain)
                        .help("Switch to \(modeLabel(for: nextMode))")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(MacbotDS.Mat.chrome)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                            .stroke(MacbotDS.Colors.separator.opacity(0.3), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    .padding(MacbotDS.Space.sm)
                    .transition(.opacity)
                }
            }
        }
        .background(
            // Invisible 0×0 button carries the ⌘⇧J mode-cycle shortcut so
            // it works whether the sidebar is collapsed or not.
            Button("") { cycleContentMode() }
                .keyboardShortcut(.init("J"), modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .hidden()
        )
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: MacbotDS.Space.sm) {
                Button(action: {
                    withAnimation(Motion.snappy) { sidebarCollapsed = true }
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.caption)
                        .foregroundStyle(MacbotDS.Colors.textTer)
                }
                .buttonStyle(.plain)
                .help("Collapse sidebar")

                Spacer()

                switch viewModel.contentMode {
                case .chat:
                    Button(action: { viewModel.newChat() }) {
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                            .foregroundStyle(MacbotDS.Colors.textSec)
                            .padding(6)
                            .background(.fill.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("New Chat")
                case .canvas:
                    Button(action: { viewModel.canvasViewModel.createCanvas() }) {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundStyle(MacbotDS.Colors.textSec)
                            .padding(6)
                            .background(.fill.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("New Canvas")
                case .notebook:
                    Button(action: { viewModel.notebookViewModel.createPageInCurrentNotebook() }) {
                        Image(systemName: "square.and.pencil")
                            .font(.caption)
                            .foregroundStyle(MacbotDS.Colors.textSec)
                            .padding(6)
                            .background(.fill.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("New Page (⌘J)")
                    .keyboardShortcut(.init("J"), modifiers: .command)
                }
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.top, MacbotDS.Space.md)
            .padding(.bottom, MacbotDS.Space.xs)

            // Mode toggle — segmented control
            HStack(spacing: 2) {
                modeButton("Notebook", icon: "book.closed", mode: .notebook)
                modeButton("Canvas", icon: "rectangle.on.rectangle.angled", mode: .canvas)
                modeButton("Chat", icon: "bubble.left.and.text.bubble.right", mode: .chat)
            }
            .padding(2)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.bottom, MacbotDS.Space.md)

            // Search
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                TextField("Search...", text: $viewModel.searchQuery)
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
            .padding(.bottom, MacbotDS.Space.md)

            // Content list — shows chats or canvases based on mode.
            // Notebook mode never renders this full sidebar (uses railSidebar),
            // so its case is unreachable but required for switch exhaustiveness.
            switch viewModel.contentMode {
            case .chat:
                if viewModel.isSearching {
                    searchResultsList
                } else {
                    chatList
                }
            case .canvas:
                canvasList
            case .notebook:
                EmptyView()
            }

            Spacer(minLength: 0)

            // Status bar
            HStack(spacing: MacbotDS.Space.sm) {
                // Live indicator
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(MacbotDS.Colors.success)
                    .symbolEffect(.pulse, isActive: true)

                Text(viewModel.isStreaming ? "Thinking..." : "On-Device")
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(viewModel.isStreaming ? MacbotDS.Colors.warning : MacbotDS.Colors.success)

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(MacbotDS.Typo.detail)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .padding(.horizontal, MacbotDS.Space.sm)
                    .padding(.vertical, MacbotDS.Space.xs)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.md)
        }
        .background(MacbotDS.Mat.chrome)
    }

    private var chatList: some View {
        let grouped = groupChatsByDate(viewModel.chats)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(grouped, id: \.label) { group in
                    Text(group.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .textCase(.uppercase)
                        .padding(.horizontal, MacbotDS.Space.md + MacbotDS.Space.sm)
                        .padding(.top, group.label == grouped.first?.label ? MacbotDS.Space.xs : MacbotDS.Space.md)
                        .padding(.bottom, MacbotDS.Space.xs)

                    ForEach(group.chats) { chat in
                        chatRow(chat)
                    }
                }
            }
            .padding(.vertical, MacbotDS.Space.xs)
        }
    }

    private struct ChatGroup {
        let label: String
        let chats: [ChatRecord]
    }

    private func groupChatsByDate(_ chats: [ChatRecord]) -> [ChatGroup] {
        let cal = Calendar.current
        let now = Date()
        var today: [ChatRecord] = []
        var thisWeek: [ChatRecord] = []
        var older: [ChatRecord] = []

        for chat in chats {
            if cal.isDateInToday(chat.updatedAt) {
                today.append(chat)
            } else if let weekAgo = cal.date(byAdding: .day, value: -7, to: now),
                      chat.updatedAt > weekAgo {
                thisWeek.append(chat)
            } else {
                older.append(chat)
            }
        }

        var groups: [ChatGroup] = []
        if !today.isEmpty { groups.append(ChatGroup(label: "Today", chats: today)) }
        if !thisWeek.isEmpty { groups.append(ChatGroup(label: "This Week", chats: thisWeek)) }
        if !older.isEmpty { groups.append(ChatGroup(label: "Older", chats: older)) }
        return groups
    }

    // MARK: - Canvas List (sidebar)

    @State private var renamingCanvasId: String?
    @State private var canvasRenameField: String = ""

    private var canvasList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.canvasViewModel.canvasList) { canvas in
                    let isSelected = viewModel.canvasViewModel.currentCanvasId == canvas.id

                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isSelected ? MacbotDS.Colors.accent : .clear)
                            .frame(width: 3)
                            .padding(.vertical, 4)

                        if renamingCanvasId == canvas.id {
                            TextField("Canvas name", text: $canvasRenameField)
                                .textFieldStyle(.plain)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(MacbotDS.Colors.textPri)
                                .padding(.horizontal, MacbotDS.Space.sm)
                                .padding(.vertical, MacbotDS.Space.sm)
                                .onSubmit {
                                    if !canvasRenameField.isEmpty {
                                        viewModel.canvasViewModel.renameCanvas(canvas.id, title: canvasRenameField)
                                    }
                                    renamingCanvasId = nil
                                }
                                .onKeyPress(.escape) {
                                    renamingCanvasId = nil
                                    return .handled
                                }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(canvas.title)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? MacbotDS.Colors.textPri : MacbotDS.Colors.textSec)
                                    .lineLimit(1)

                                Text("\(viewModel.canvasViewModel.currentCanvasId == canvas.id ? viewModel.canvasViewModel.nodes.count : 0) nodes")
                                    .font(.caption2)
                                    .foregroundStyle(MacbotDS.Colors.textTer)
                            }
                            .padding(.horizontal, MacbotDS.Space.sm)
                            .padding(.vertical, MacbotDS.Space.sm)
                        }
                    }
                    .padding(.leading, MacbotDS.Space.sm)
                    .padding(.trailing, MacbotDS.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.canvasViewModel.switchCanvas(canvas.id) }
                    .padding(.horizontal, MacbotDS.Space.xs)
                    .contextMenu {
                        Button("Rename") {
                            canvasRenameField = canvas.title
                            renamingCanvasId = canvas.id
                        }
                        if viewModel.canvasViewModel.canvasList.count > 1 {
                            Button("Delete", role: .destructive) {
                                viewModel.canvasViewModel.deleteCanvas(canvas.id)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, MacbotDS.Space.xs)
        }
    }

    // MARK: - Rail sidebar (notebook mode)

    /// Narrow icon rail shown in notebook mode so the app-level chrome
    /// doesn't compete with NotebookView's own notebooks pane. Preserves
    /// mode switching, sidebar collapse, and new-page entry while freeing
    /// horizontal space for the editor.
    private var railSidebar: some View {
        VStack(spacing: MacbotDS.Space.md) {
            Button(action: {
                withAnimation(Motion.snappy) { sidebarCollapsed = true }
            }) {
                Image(systemName: "sidebar.left")
                    .font(.callout)
                    .foregroundStyle(MacbotDS.Colors.textTer)
                    .frame(width: 36, height: 28)
            }
            .buttonStyle(.plain)
            .help("Collapse sidebar")

            Divider()
                .padding(.horizontal, MacbotDS.Space.xs)

            railModeButton(icon: "book.closed", mode: .notebook, help: "Notebook")
            railModeButton(icon: "rectangle.on.rectangle.angled", mode: .canvas, help: "Canvas")
            railModeButton(icon: "bubble.left.and.text.bubble.right", mode: .chat, help: "Chat")

            Divider()
                .padding(.horizontal, MacbotDS.Space.xs)

            Button(action: { viewModel.notebookViewModel.createPageInCurrentNotebook() }) {
                Image(systemName: "square.and.pencil")
                    .font(.callout)
                    .foregroundStyle(MacbotDS.Colors.textSec)
                    .frame(width: 36, height: 28)
                    .background(.fill.tertiary)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("New Page (⌘J)")
            .keyboardShortcut(.init("J"), modifiers: .command)

            Spacer()
        }
        .padding(.vertical, MacbotDS.Space.md)
        .frame(maxHeight: .infinity)
        .background(MacbotDS.Mat.chrome)
    }

    private func railModeButton(icon: String, mode: ContentMode, help: String) -> some View {
        let isActive = viewModel.contentMode == mode
        return Button(action: {
            withAnimation(Motion.snappy) {
                if mode == .canvas {
                    viewModel.refreshCanvasChats()
                    viewModel.setupCanvas()
                }
                if mode == .notebook {
                    viewModel.setupNotebook()
                }
                viewModel.contentMode = mode
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? MacbotDS.Colors.textPri : MacbotDS.Colors.textTer)
                .frame(width: 36, height: 28)
                .background(isActive ? AnyShapeStyle(MacbotDS.Mat.chrome) : AnyShapeStyle(.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isActive ? MacbotDS.Colors.separator.opacity(0.4) : .clear, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: isActive ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Mode cycle helpers (top-bar quick toggle)

    private var nextMode: ContentMode {
        switch viewModel.contentMode {
        case .notebook: return .canvas
        case .canvas:   return .chat
        case .chat:     return .notebook
        }
    }

    private func modeIcon(for mode: ContentMode) -> String {
        switch mode {
        case .notebook: return "book.closed"
        case .canvas:   return "rectangle.on.rectangle.angled"
        case .chat:     return "bubble.left.and.text.bubble.right"
        }
    }

    private func modeLabel(for mode: ContentMode) -> String {
        switch mode {
        case .notebook: return "Notebook"
        case .canvas:   return "Canvas"
        case .chat:     return "Chat"
        }
    }

    private func cycleContentMode() {
        withAnimation(Motion.snappy) {
            let target = nextMode
            switch target {
            case .canvas:
                viewModel.refreshCanvasChats()
                viewModel.setupCanvas()
            case .notebook:
                viewModel.setupNotebook()
            case .chat:
                break
            }
            viewModel.contentMode = target
        }
    }

    private func modeButton(_ title: String, icon: String, mode: ContentMode) -> some View {
        let isActive = viewModel.contentMode == mode
        return Button(action: {
            withAnimation(Motion.snappy) {
                if mode == .canvas {
                    viewModel.refreshCanvasChats()
                    viewModel.setupCanvas()
                }
                if mode == .notebook {
                    viewModel.setupNotebook()
                }
                viewModel.contentMode = mode
            }
        }) {
            HStack(spacing: MacbotDS.Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isActive ? MacbotDS.Colors.textPri : MacbotDS.Colors.textTer)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(isActive ? AnyShapeStyle(MacbotDS.Mat.chrome) : AnyShapeStyle(.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: isActive ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
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
