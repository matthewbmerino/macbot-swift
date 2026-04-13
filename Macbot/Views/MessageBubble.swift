import SwiftUI
import MarkdownUI

struct MessageBubble: View {
    let message: ChatMessage
    var onEdit: (() -> Void)?
    /// When true, uses plain Text instead of Markdown for performance.
    /// Markdown parsing is expensive; during streaming we skip it.
    var isStreaming: Bool = false
    @State private var isHovering = false
    @State private var expandedImage: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: MacbotDS.Space.xs) {
            // Header
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: message.role == .user ? "person.circle.fill" : "cube.transparent.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(message.role == .user ? MacbotDS.Colors.textSec : MacbotDS.Colors.accent)

                Text(message.role == .user ? "You" : "macbot")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == .user ? MacbotDS.Colors.textPri : MacbotDS.Colors.accent)

                if let agent = message.agentCategory {
                    AgentBadge(category: agent)
                }

                Spacer()

                // Action buttons (visible on hover)
                if isHovering && !message.content.isEmpty {
                    HStack(spacing: MacbotDS.Space.xs) {
                        if message.role == .user, let onEdit {
                            Button(action: onEdit) {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(MacbotDS.Colors.textTer)
                                    .frame(width: 22, height: 22)
                                    .background(.fill.tertiary)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("Edit & resend")
                        }

                        Button(action: { copyToClipboard() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(MacbotDS.Colors.textTer)
                                .frame(width: 22, height: 22)
                                .background(.fill.tertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Copy message")
                    }
                    .transition(.opacity)
                }
            }

            // Content
            if !message.content.isEmpty {
                if message.role == .assistant {
                    if isStreaming {
                        // Plain text during streaming — Markdown parsing
                        // is too expensive at 10 updates/sec.
                        Text(message.content)
                            .font(MacbotDS.Typo.body)
                            .textSelection(.enabled)
                    } else {
                        // Full Markdown rendering after streaming completes.
                        Markdown(message.content)
                            .markdownTextStyle {
                                FontSize(13)
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
                            .textSelection(.enabled)
                    }
                } else {
                    Text(message.content)
                        .font(MacbotDS.Typo.body)
                        .textSelection(.enabled)
                }
            }

            // Images
            if let images = message.images, !images.isEmpty {
                imageGrid(images)
            }

        }
        .padding(.horizontal, MacbotDS.Space.lg)
        .padding(.vertical, MacbotDS.Space.md)
        .background(
            message.role == .user
                ? AnyShapeStyle(.fill.tertiary)
                : AnyShapeStyle(.fill.quinary)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacbotDS.Radius.md, style: .continuous)
                .stroke(
                    message.role == .assistant
                        ? MacbotDS.Colors.separator.opacity(0.3)
                        : .clear,
                    lineWidth: 0.5
                )
        )
        .onHover { isHovering = $0 }
        .animation(Motion.snappy, value: isHovering)
        .sheet(item: $expandedImage) { data in
            ImageViewer(imageData: data)
        }
    }

    // MARK: - Image Grid

    private func imageGrid(_ images: [Data]) -> some View {
        HStack(spacing: MacbotDS.Space.sm) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                if let nsImage = NSImage(data: data) {
                    ImageThumbnail(nsImage: nsImage) {
                        expandedImage = data
                    }
                }
            }
        }
        .padding(.top, MacbotDS.Space.xs)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }
}

// MARK: - Image Thumbnail (in chat)

struct ImageThumbnail: View {
    let nsImage: NSImage
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 350, maxHeight: 250)
                .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                        .stroke(MacbotDS.Colors.separator.opacity(isHovering ? 1 : 0), lineWidth: 1)
                )
                .shadow(color: .black.opacity(isHovering ? 0.15 : 0), radius: 8)

            // Expand hint on hover
            if isHovering {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .padding(MacbotDS.Space.sm)
                    .background(MacbotDS.Mat.float)
                    .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                    .padding(MacbotDS.Space.sm)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .cursor(.pointingHand)
        .animation(Motion.snappy, value: isHovering)
    }
}

// MARK: - Expanded Image Viewer

struct ImageViewer: View {
    let imageData: Data
    @Environment(\.dismiss) private var dismiss
    @State private var isHoveringCopy = false
    @State private var isHoveringSave = false
    @State private var isHoveringClose = false
    @State private var showSavedCheck = false

    private var nsImage: NSImage? { NSImage(data: imageData) }

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: MacbotDS.Space.md) {
                    Spacer()

                    toolbarButton(
                        icon: showSavedCheck ? "checkmark" : "doc.on.doc",
                        label: showSavedCheck ? "Copied" : "Copy",
                        isHovering: $isHoveringCopy
                    ) {
                        copyImage()
                    }

                    toolbarButton(
                        icon: "arrow.down.circle",
                        label: "Save",
                        isHovering: $isHoveringSave
                    ) {
                        saveImage()
                    }

                    toolbarButton(
                        icon: "xmark",
                        label: "Close",
                        isHovering: $isHoveringClose
                    ) {
                        dismiss()
                    }
                }
                .padding(.horizontal, MacbotDS.Space.lg)
                .padding(.top, MacbotDS.Space.md)
                .padding(.bottom, MacbotDS.Space.md)

                // Image
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(MacbotDS.Space.lg)
                } else {
                    Text("Unable to display image")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 450)
        .onExitCommand { dismiss() }
    }

    private func toolbarButton(
        icon: String,
        label: String,
        isHovering: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: MacbotDS.Space.sm) {
                Image(systemName: icon)
                    .font(.caption.weight(.medium))
                if isHovering.wrappedValue {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity
                        ))
                }
            }
            .foregroundStyle(isHovering.wrappedValue ? .white : .white.opacity(0.6))
            .padding(.horizontal, isHovering.wrappedValue ? MacbotDS.Space.md : MacbotDS.Space.sm)
            .padding(.vertical, MacbotDS.Space.sm)
            .background(.fill.secondary)
            .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering.wrappedValue = $0 }
        .animation(Motion.snappy, value: isHovering.wrappedValue)
    }

    private func copyImage() {
        guard let nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
        withAnimation { showSavedCheck = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showSavedCheck = false }
        }
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "macbot_chart.png"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let tiffData = nsImage?.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
            }
        }
    }
}

// MARK: - Data + Identifiable for sheet binding

extension Data: @retroactive Identifiable {
    public var id: Int { hashValue }
}

// MARK: - Cursor modifier

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
