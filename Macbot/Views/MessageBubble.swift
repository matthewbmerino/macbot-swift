import SwiftUI
import MarkdownUI

struct MessageBubble: View {
    let message: ChatMessage
    @State private var isHovering = false
    @State private var expandedImage: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.circle.fill" : "cube.transparent")
                    .font(.caption)
                    .foregroundStyle(message.role == .user ? .primary : Color.accentColor)

                Text(message.role == .user ? "You" : "Macbot")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(message.role == .user ? .primary : Color.accentColor)

                if let agent = message.agentCategory {
                    AgentBadge(category: agent)
                }

                Spacer()

                // Copy button (visible on hover)
                if isHovering && !message.content.isEmpty {
                    Button(action: { copyToClipboard() }) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy message")
                    .transition(.opacity)
                }

                Text(message.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            // Content
            if !message.content.isEmpty {
                if message.role == .assistant {
                    Markdown(message.content)
                        .markdownTextStyle {
                            FontSize(14)
                        }
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            configuration.label
                                .padding(12)
                                .background(.quaternary.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.quaternary, lineWidth: 1)
                                )
                        }
                        .textSelection(.enabled)
                } else {
                    Text(message.content)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            // Images
            if let images = message.images, !images.isEmpty {
                imageGrid(images)
            }

            // Response metrics
            if let metrics = message.metricsString {
                Text(metrics)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .sheet(item: $expandedImage) { data in
            ImageViewer(imageData: data)
        }
    }

    // MARK: - Image Grid

    private func imageGrid(_ images: [Data]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                if let nsImage = NSImage(data: data) {
                    ImageThumbnail(nsImage: nsImage) {
                        expandedImage = data
                    }
                }
            }
        }
        .padding(.top, 4)
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
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(isHovering ? 0.15 : 0), lineWidth: 1)
                )
                .shadow(color: .black.opacity(isHovering ? 0.3 : 0), radius: 8)

            // Expand hint on hover
            if isHovering {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .padding(5)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .cursor(.pointingHand)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
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
                HStack(spacing: 12) {
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
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Image
                if let nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
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
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                if isHovering.wrappedValue {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity
                        ))
                }
            }
            .foregroundStyle(isHovering.wrappedValue ? .white : .white.opacity(0.6))
            .padding(.horizontal, isHovering.wrappedValue ? 10 : 7)
            .padding(.vertical, 6)
            .background(.white.opacity(isHovering.wrappedValue ? 0.12 : 0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering.wrappedValue = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering.wrappedValue)
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
