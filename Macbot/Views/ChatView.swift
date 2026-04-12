import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

// MARK: - Design System (Apple-native)

private enum DS {
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let cornerRadius: CGFloat = 16
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

            Divider()

            chatContent
        }
        .background(DS.bg)
        .frame(minWidth: 700, minHeight: 520)
        .onAppear { inputFocused = true }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("macbot")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)

                Spacer()

                Button(action: { viewModel.newChat() }) {
                    Image(systemName: "square.and.pencil")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                        .padding(6)
                        .background(.fill.tertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New Chat")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(DS.textTertiary)
                TextField("Search...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DS.textPrimary)
                    .onChange(of: viewModel.searchQuery) { _, _ in viewModel.search() }
                if !viewModel.searchQuery.isEmpty {
                    Button(action: { viewModel.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            // Chat list
            if viewModel.isSearching {
                searchResultsList
            } else {
                chatList
            }

            Spacer(minLength: 0)

            // Status bar
            HStack(spacing: 8) {
                // Live indicator
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, isActive: true)

                Text(viewModel.isStreaming ? "Thinking..." : "On-Device")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(viewModel.isStreaming ? .orange : .green)

                Spacer()

                Text(viewModel.activeAgent.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.fill.tertiary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial)
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
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)

                HStack {
                    Text(chat.lastMessage)
                        .font(.caption2)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    Text(chat.updatedAt, style: .relative)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu {
            Button("Delete", role: .destructive) { viewModel.deleteChat(chat.id) }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            if viewModel.searchResults.isEmpty {
                Text("No results")
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { _, result in
                        Button(action: { viewModel.selectChat(result.message.chatId) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.chatTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(DS.textPrimary)
                                    .lineLimit(1)
                                Text(result.message.content)
                                    .font(.caption2)
                                    .foregroundStyle(DS.textTertiary)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
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
                        emptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .containerRelativeFrame(.vertical) { height, _ in height }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.messages) { msg in
                                MessageBubble(message: msg) {
                                    viewModel.startEditing(message: msg)
                                    inputFocused = true
                                }
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
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
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
        .background(DS.bg)
        .onDrop(of: [.image, .fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay {
            if dragOver {
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    .background(.ultraThinMaterial.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 28, weight: .light))
                                .symbolRenderingMode(.hierarchical)
                            Text("Drop image to analyze")
                                .font(.subheadline.weight(.medium))
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
                    .fill(.fill.tertiary)
                    .frame(width: 80, height: 80)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 40, weight: .ultraLight))
                    .foregroundStyle(DS.textTertiary)
                    .symbolRenderingMode(.hierarchical)
            }

            Text("What can I help with?")
                .font(.title3.weight(.medium))
                .foregroundStyle(DS.textSecondary)

            Text("All processing happens on this Mac.\nNothing leaves your network.")
                .font(.subheadline)
                .foregroundStyle(DS.textTertiary)
                .multilineTextAlignment(.center)

            Spacer()
            Color.clear.frame(height: 80)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        TypingDots()
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
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DS.separator, lineWidth: 0.5))

                            Button(action: { viewModel.pendingImages.remove(at: idx) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .background(Circle().fill(.ultraThinMaterial))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Floating Input Bar

    private var floatingInputBar: some View {
        VStack(spacing: 8) {
            // Editing indicator
            if viewModel.editingMessageId != nil {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption)
                        .tint(.orange)
                        .foregroundStyle(.orange)
                    Text("Editing message — press Enter to resend")
                        .font(.caption2)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    Button("Cancel") {
                        viewModel.editingMessageId = nil
                        viewModel.inputText = ""
                    }
                    .font(.caption2)
                    .foregroundStyle(DS.textTertiary)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 12) {
                Button(action: { pickImage() }) {
                    Image(systemName: "paperclip")
                        .font(.subheadline)
                        .foregroundStyle(DS.textTertiary)
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
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { sendMessage() }

                if viewModel.isStreaming {
                    // Stop button replaces send during streaming
                    Button(action: { viewModel.cancelStream() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.orange)
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
                            .foregroundStyle(canSend ? Color.accentColor : DS.textTertiary.opacity(0.3))
                    }
                    .disabled(!canSend)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(
                viewModel.editingMessageId != nil ? .orange.opacity(0.3) : DS.separator,
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
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
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
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: phase)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
