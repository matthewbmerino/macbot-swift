import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

// MARK: - Obsidian Design Tokens

private enum ODS {
    static let bg = Color(red: 0.067, green: 0.067, blue: 0.067)           // #111111
    static let surface = Color(red: 0.102, green: 0.102, blue: 0.102)      // #1A1A1A
    static let surfaceHover = Color(red: 0.133, green: 0.133, blue: 0.133) // #222222
    static let border = Color.white.opacity(0.1)
    static let borderSubtle = Color.white.opacity(0.05)
    static let textPrimary = Color.white.opacity(0.9)
    static let textSecondary = Color.white.opacity(0.5)
    static let textTertiary = Color.white.opacity(0.3)
    static let cornerRadius: CGFloat = 24
    static let innerRadius: CGFloat = 16
}

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var inputFocused: Bool
    @State private var dragOver = false
    @State private var livePulse = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)

            // Subtle vertical divider
            Rectangle()
                .fill(ODS.borderSubtle)
                .frame(width: 0.5)

            chatContent
        }
        .background(ODS.bg)
        .frame(minWidth: 700, minHeight: 520)
        .onAppear { inputFocused = true }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Text("Macbot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ODS.textPrimary)

                Spacer()

                Button(action: { viewModel.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(ODS.textSecondary)
                        .padding(6)
                        .background(.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("New Chat")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(ODS.textTertiary)
                TextField("Search...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(ODS.textPrimary)
                    .onChange(of: viewModel.searchQuery) { _, _ in viewModel.search() }
                if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(ODS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ODS.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ODS.borderSubtle, lineWidth: 0.5))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            // Chat list
            if viewModel.isSearching {
                searchResultsList
            } else {
                chatList
            }

            Spacer(minLength: 0)

            // Status bar
            HStack(spacing: 6) {
                // Live indicator
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
                    .opacity(livePulse ? 1.0 : 0.35)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                            livePulse = true
                        }
                    }

                Text(viewModel.isStreaming ? "Thinking..." : "On-Device")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(viewModel.isStreaming ? .orange.opacity(0.7) : .green.opacity(0.5))

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(ODS.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.04))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var chatList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.chats) { chat in
                    chatRow(chat)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func chatRow(_ chat: ChatRecord) -> some View {
        let isSelected = viewModel.currentChatId == chat.id

        return Button(action: { viewModel.selectChat(chat.id) }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? ODS.textPrimary : ODS.textSecondary)
                    .lineLimit(1)

                HStack {
                    Text(chat.lastMessage)
                        .font(.system(size: 9))
                        .foregroundStyle(ODS.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    Text(chat.updatedAt, style: .relative)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(ODS.textTertiary.opacity(0.6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? .white.opacity(0.06) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .contextMenu {
            Button("Delete", role: .destructive) { viewModel.deleteChat(chat.id) }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            if viewModel.searchResults.isEmpty {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundStyle(ODS.textTertiary)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { _, result in
                        Button(action: { viewModel.selectChat(result.message.chatId) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.chatTitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(ODS.textPrimary)
                                    .lineLimit(1)
                                Text(result.message.content)
                                    .font(.system(size: 9))
                                    .foregroundStyle(ODS.textTertiary)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 4)
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
                        GeometryReader { geo in
                            emptyState
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }

                            if let status = viewModel.currentStatus {
                                StatusIndicator(text: status)
                                    .padding(.horizontal, 20)
                                    .id("status")
                            }

                            if viewModel.isStreaming && viewModel.currentStatus == nil
                                && viewModel.messages.last?.role == .user {
                                typingIndicator.id("typing")
                            }

                            // Spacer for floating input
                            Color.clear.frame(height: 80)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .onChange(of: viewModel.messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let lastId = viewModel.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            // Activity terminal + floating input
            VStack(spacing: 8) {
                ActivityTerminal()

                if !viewModel.pendingImages.isEmpty {
                    imagePreview
                }

                floatingInputBar
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(ODS.bg)
        .onDrop(of: [.image, .fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if dragOver {
                RoundedRectangle(cornerRadius: ODS.cornerRadius)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    .background(.ultraThinMaterial.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: ODS.cornerRadius))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 28, weight: .light))
                            Text("Drop image to analyze")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                    }
                    .padding(4)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(.white.opacity(0.03))
                    .frame(width: 80, height: 80)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 32, weight: .thin))
                    .foregroundStyle(ODS.textTertiary)
            }

            Text("What can I help with?")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ODS.textSecondary)

            Text("All processing happens on this Mac.\nNothing leaves your network.")
                .font(.system(size: 12))
                .foregroundStyle(ODS.textTertiary)
                .multilineTextAlignment(.center)

            Spacer()
            Color.clear.frame(height: 80)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.3))
                    .frame(width: 5, height: 5)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever()
                        .delay(Double(i) * 0.15),
                        value: viewModel.isStreaming
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Image Preview

    private var imagePreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.offset) { idx, data in
                    if let nsImage = NSImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ODS.border, lineWidth: 0.5))

                            Button(action: { viewModel.pendingImages.remove(at: idx) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .background(Circle().fill(.black.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Floating Input Bar

    private var floatingInputBar: some View {
        HStack(spacing: 10) {
            Button(action: { pickImage() }) {
                Image(systemName: "paperclip")
                    .font(.system(size: 13))
                    .foregroundStyle(ODS.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Attach image")

            TextField("Message Macbot...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ODS.textPrimary)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { sendMessage() }
                .disabled(viewModel.isStreaming)

            Button(action: { sendMessage() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Color.accentColor : ODS.textTertiary.opacity(0.3))
            }
            .disabled(!canSend)
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ODS.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(ODS.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var canSend: Bool {
        (!viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty || !viewModel.pendingImages.isEmpty)
        && !viewModel.isStreaming
    }

    // MARK: - Actions

    private func sendMessage() {
        viewModel.send()
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
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.05))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}
