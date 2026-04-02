import Foundation
import SwiftUI

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

        Task {
            var responseText = ""
            var agentCategory: AgentCategory?

            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: userId, message: messageText, images: attachedImages
                ) {
                    await MainActor.run {
                        switch event {
                        case .text(let chunk):
                            responseText += chunk
                            currentStatus = nil
                            updateLastAgentMessage(responseText, agent: agentCategory)

                        case .status(let status):
                            currentStatus = status

                        case .agentSelected(let category):
                            agentCategory = category
                            activeAgent = category

                        case .image(let data, _):
                            if var last = messages.last, last.role == .assistant {
                                messages.removeLast()
                                var imgs = last.images ?? []
                                imgs.append(data)
                                last.images = imgs
                                messages.append(last)
                            } else {
                                // No assistant message yet — create one for the image
                                var msg = ChatMessage(role: .assistant, content: "", agentCategory: agentCategory)
                                msg.images = [data]
                                messages.append(msg)
                            }
                        }
                    }
                }
            } catch {
                let errorMsg = "Something went wrong: \(error.localizedDescription)"
                Log.agents.error("Chat error: \(error)")
                await MainActor.run {
                    updateLastAgentMessage(errorMsg, agent: agentCategory)
                    responseText = errorMsg
                }
            }

            await MainActor.run {
                if messages.last?.role != .assistant {
                    let fallback = responseText.isEmpty
                        ? "No response — Ollama may still be loading. Try again in a moment."
                        : responseText
                    messages.append(ChatMessage(role: .assistant, content: fallback, agentCategory: agentCategory))
                    responseText = fallback
                }
                isStreaming = false
                currentStatus = nil

                // Persist assistant message
                chatStore.saveMessage(
                    chatId: chatId, role: "assistant", content: responseText,
                    agentCategory: agentCategory?.rawValue
                )
                loadChatList()
            }
        }
    }

    @MainActor
    private func updateLastAgentMessage(_ text: String, agent: AgentCategory?) {
        if let last = messages.last, last.role == .assistant {
            messages[messages.count - 1] = ChatMessage(
                role: .assistant, content: text, agentCategory: agent
            )
        } else {
            messages.append(ChatMessage(
                role: .assistant, content: text, agentCategory: agent
            ))
        }
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
