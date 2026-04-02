import SwiftUI
import AppKit

// MARK: - Quick Panel Window Controller

final class QuickPanelController {
    static let shared = QuickPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<QuickPanelView>?
    private var viewModel: QuickPanelViewModel?
    var orchestrator: Orchestrator?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show(prefill: String? = nil) {
        guard let orchestrator else {
            Log.app.warning("QuickPanel: no orchestrator set")
            return
        }

        if panel == nil {
            createPanel(orchestrator: orchestrator)
        }

        if let prefill {
            viewModel?.inputText = prefill
        }

        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()

        // Focus the text field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.panel?.makeFirstResponder(nil)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        viewModel?.reset()
    }

    private func createPanel(orchestrator: Orchestrator) {
        let vm = QuickPanelViewModel(orchestrator: orchestrator)
        vm.onDismiss = { [weak self] in self?.hide() }
        self.viewModel = vm

        let content = QuickPanelView(viewModel: vm)
        let hosting = NSHostingView(rootView: content)
        self.hostingView = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 80),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hosting

        // Close on Escape
        panel.isReleasedWhenClosed = false

        // Auto-resize based on content
        hosting.translatesAutoresizingMaskIntoConstraints = false

        self.panel = panel
    }
}

// MARK: - Quick Panel ViewModel

@Observable
final class QuickPanelViewModel {
    var inputText = ""
    var responseText = ""
    var isStreaming = false
    var activeAgent: AgentCategory?
    var currentStatus: String?
    var onDismiss: (() -> Void)?

    private let orchestrator: Orchestrator
    private let userId = "quick"

    init(orchestrator: Orchestrator) {
        self.orchestrator = orchestrator
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        inputText = ""
        responseText = ""
        isStreaming = true
        currentStatus = nil
        activeAgent = nil

        Task {
            do {
                for try await event in orchestrator.handleMessageStream(
                    userId: userId, message: text
                ) {
                    await MainActor.run {
                        switch event {
                        case .text(let chunk):
                            responseText += chunk
                            currentStatus = nil
                        case .status(let status):
                            currentStatus = status
                        case .agentSelected(let category):
                            activeAgent = category
                        case .image:
                            break
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    responseText = "Error: \(error.localizedDescription)"
                }
            }

            await MainActor.run {
                isStreaming = false
                currentStatus = nil
            }
        }
    }

    func reset() {
        inputText = ""
        responseText = ""
        isStreaming = false
        currentStatus = nil
        activeAgent = nil
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(responseText, forType: .string)
    }
}

// MARK: - Quick Panel View

struct QuickPanelView: View {
    @Bindable var viewModel: QuickPanelViewModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: 10) {
                Image(systemName: "brain")
                    .foregroundStyle(Color.accentColor)
                    .font(.body)

                TextField("Ask anything...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($inputFocused)
                    .onSubmit { viewModel.send() }

                if viewModel.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                } else if !viewModel.inputText.isEmpty {
                    Button(action: { viewModel.send() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Response (only shown when there's content)
            if !viewModel.responseText.isEmpty || viewModel.currentStatus != nil {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    // Agent badge
                    if let agent = viewModel.activeAgent {
                        HStack(spacing: 4) {
                            Text(agent.displayName)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .clipShape(Capsule())
                            Spacer()

                            if !viewModel.responseText.isEmpty && !viewModel.isStreaming {
                                Button(action: { viewModel.copyResult() }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy to clipboard")
                            }
                        }
                    }

                    if let status = viewModel.currentStatus {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                    }

                    if !viewModel.responseText.isEmpty {
                        Text(viewModel.responseText)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .lineLimit(12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .onAppear { inputFocused = true }
        .onExitCommand { viewModel.onDismiss?() }
    }
}
