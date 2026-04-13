import Foundation
import SwiftUI

/// Mutable accumulator for a single streaming send. Pinned to `@MainActor`
/// so the detached inference task and each `MainActor.run` hop can share a
/// Sendable reference without tripping Swift 6's captured-var rules. All
/// mutations are serialized on the main actor.
@MainActor
final class ChatStreamAccumulator {
    var responseText: String = ""
    var agentCategory: AgentCategory?
    var lastFlushTime: CFAbsoluteTime = 0
    /// Minimum interval between UI updates during streaming.
    /// Prevents re-rendering Markdown 30-50x/sec on fast streams.
    static let flushInterval: CFAbsoluteTime = 0.1  // 10 fps max
}

@Observable
final class ChatViewModel {
    // Current chat state
    var messages: [ChatMessage] = []
    var isStreaming = false
    var currentStatus: String?
    var activeAgent: AgentCategory = .general
    var inputText = ""
    var pendingImages: [Data] = []

    // Chat list
    var chats: [ChatRecord] = []
    var currentChatId: String?
    var searchQuery = ""
    var searchResults: [(message: ChatMessageRecord, chatTitle: String)] = []
    var isSearching = false

    private let orchestrator: Orchestrator
    private let chatStore = ChatStore()
    private let userId = "local"
    private var streamTask: Task<Void, Never>?

    /// The message ID currently being edited. When set, the input bar shows
    /// the edited text and the send button becomes "Resend".
    var editingMessageId: UUID?

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
        loadChatList()
    }

    // MARK: - Chat List

    func loadChatList() {
        chats = chatStore.listChats()
    }

    func newChat() {
        let chat = chatStore.createChat()
        currentChatId = chat.id
        messages = []
        loadChatList()

        // Clear agent history for fresh context
        Task {
            _ = try? await orchestrator.handleMessage(userId: userId, message: "/clear")
        }
    }

    func selectChat(_ chatId: String) {
        currentChatId = chatId
        let records = chatStore.loadMessages(chatId: chatId)
        messages = records.map { record in
            ChatMessage(
                role: MessageRole(rawValue: record.role) ?? .user,
                content: record.content,
                agentCategory: record.agentCategory.flatMap { AgentCategory(rawValue: $0) }
            )
        }

        // Clear and replay context for the orchestrator
        Task {
            _ = try? await orchestrator.handleMessage(userId: userId, message: "/clear")
        }
    }

    func deleteChat(_ chatId: String) {
        chatStore.deleteChat(id: chatId)
        if currentChatId == chatId {
            currentChatId = nil
            messages = []
        }
        loadChatList()
    }

    // MARK: - Search

    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchResults = chatStore.searchMessages(query: query)
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        isSearching = false
    }

    // MARK: - Send

    @MainActor
    func send(images: [Data]? = nil) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingImages.isEmpty else { return }

        // Ensure we have a chat
        if currentChatId == nil {
            let chat = chatStore.createChat()
            currentChatId = chat.id
            loadChatList()
        }

        let chatId = currentChatId!
        let attachedImages = images ?? (pendingImages.isEmpty ? nil : pendingImages)
        let messageText = text.isEmpty ? "What's in this image?" : text
        inputText = ""
        pendingImages = []

        // Auto-title from first message
        if messages.isEmpty {
            chatStore.autoTitle(chatId: chatId, firstMessage: messageText)
            loadChatList()
        }

        // Add user message
        var userMsg = ChatMessage(role: .user, content: messageText)
        userMsg.images = attachedImages
        messages.append(userMsg)
        isStreaming = true
        currentStatus = nil

        // Persist user message
        chatStore.saveMessage(chatId: chatId, role: "user", content: messageText)

        // Detach from MainActor so inference runs on a background thread.
        // UI updates hop back to MainActor explicitly. Streaming state is
        // held in a `@MainActor` accumulator so it can be shared across the
        // detached task and every `MainActor.run` hop without tripping
        // Swift 6's captured-var rules.
        let uid = userId
        let acc = ChatStreamAccumulator()
        streamTask = Task.detached { [orchestrator, chatStore] in
            let userId = uid
            let startTime = CFAbsoluteTimeGetCurrent()

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: userId, message: messageText, images: attachedImages
                ) {
                    // Respect cancellation from cancelStream()
                    try Task.checkCancellation()
                    await MainActor.run { [self] in
                        switch event {
                        case .text(let chunk):
                            acc.responseText += chunk
                            self.currentStatus = nil
                            // Throttle UI updates to avoid re-rendering
                            // Markdown on every chunk (30-50x/sec kills perf).
                            let now = CFAbsoluteTimeGetCurrent()
                            guard now - acc.lastFlushTime >= ChatStreamAccumulator.flushInterval else { break }
                            acc.lastFlushTime = now
                            self.updateLastAgentMessage(acc.responseText, agent: acc.agentCategory)

                        case .status(let status):
                            self.currentStatus = status

                        case .agentSelected(let category):
                            acc.agentCategory = category
                            self.activeAgent = category

                        case .image(let data, _):
                            if var last = self.messages.last, last.role == .assistant {
                                self.messages.removeLast()
                                var imgs = last.images ?? []
                                imgs.append(data)
                                last.images = imgs
                                self.messages.append(last)
                            } else {
                                var msg = ChatMessage(role: .assistant, content: "", agentCategory: acc.agentCategory)
                                msg.images = [data]
                                self.messages.append(msg)
                            }
                        }
                    }
                }
            } catch is CancellationError {
                // User cancelled — keep the partial response, don't show an error
                Log.agents.info("Stream cancelled by user")
            } catch {
                let errorMsg = "Something went wrong: \(error.localizedDescription)"
                Log.agents.error("Chat error: \(error)")
                await MainActor.run { [self] in
                    self.updateLastAgentMessage(errorMsg, agent: acc.agentCategory)
                    acc.responseText = errorMsg
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            await MainActor.run { [self] in
                // Final flush — the throttle may have skipped the last chunk
                self.updateLastAgentMessage(acc.responseText, agent: acc.agentCategory)
                let responseText = acc.responseText
                let agentCategory = acc.agentCategory
                let tokens = TokenEstimator.estimate(responseText)
                let tps = elapsed > 0 ? Double(tokens) / elapsed : 0
                let modelName: String? = agentCategory.map { self.orchestrator.modelName(for: $0) }

                if self.messages.last?.role != .assistant {
                    let fallback = responseText.isEmpty
                        ? "No response — Ollama may still be loading. Try again in a moment."
                        : responseText
                    var msg = ChatMessage(role: .assistant, content: fallback, agentCategory: agentCategory)
                    msg.responseTime = elapsed
                    msg.tokenCount = tokens
                    msg.tokensPerSecond = tps
                    msg.modelName = modelName
                    self.messages.append(msg)
                } else {
                    self.messages[self.messages.count - 1].responseTime = elapsed
                    self.messages[self.messages.count - 1].tokenCount = tokens
                    self.messages[self.messages.count - 1].tokensPerSecond = tps
                    self.messages[self.messages.count - 1].modelName = modelName
                }
                self.isStreaming = false
                self.currentStatus = nil

                chatStore.saveMessage(
                    chatId: chatId, role: "assistant", content: responseText,
                    agentCategory: agentCategory?.rawValue
                )
                self.loadChatList()
            }
        }
    }

    @MainActor
    private func updateLastAgentMessage(_ text: String, agent: AgentCategory?) {
        if var last = messages.last, last.role == .assistant {
            // Preserve existing images when updating text
            let existingImages = last.images
            var updated = ChatMessage(role: .assistant, content: text, agentCategory: agent)
            updated.images = existingImages
            messages[messages.count - 1] = updated
        } else {
            messages.append(ChatMessage(
                role: .assistant, content: text, agentCategory: agent
            ))
        }
    }

    // MARK: - Cancel / Edit / Resend

    /// Stop the current generation mid-stream. The partial response is kept
    /// in the message list so the user can see what was generated before
    /// cancellation.
    @MainActor
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        currentStatus = nil
    }

    /// Begin editing a previously-sent user message. Populates the input
    /// bar with the message text and sets `editingMessageId` so the UI can
    /// show "Resend" instead of "Send".
    @MainActor
    func startEditing(message: ChatMessage) {
        guard message.role == .user else { return }
        // Cancel any in-flight generation first
        cancelStream()
        editingMessageId = message.id
        inputText = message.content
    }

    /// Resend after editing. Removes everything from the edited message
    /// onward (the old user message + the assistant response that followed
    /// it), then sends the new text as a fresh turn.
    @MainActor
    func resendEdited() {
        guard let editId = editingMessageId else {
            send()
            return
        }
        // Find the index of the message being edited
        if let idx = messages.firstIndex(where: { $0.id == editId }) {
            // Remove from that message onward (user msg + all subsequent)
            messages.removeSubrange(idx...)
        }
        editingMessageId = nil
        send()
    }

    func clearConversation() {
        messages.removeAll()
        if let chatId = currentChatId {
            chatStore.deleteChat(id: chatId)
        }
        currentChatId = nil
        loadChatList()
        Task {
            _ = try? await orchestrator.handleMessage(userId: userId, message: "/clear")
        }
    }
}
