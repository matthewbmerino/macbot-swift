import SwiftUI
import AppKit

struct OverlayView: View {
    @Bindable var viewModel: OverlayViewModel

    var body: some View {
        ZStack {
            // Layer 1: Captured screen + dim overlay
            if let capture = viewModel.screenCapture {
                Image(nsImage: capture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()

                Color.black.opacity(0.4)
                    .ignoresSafeArea()
            } else {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
            }

            // Permission denied message
            if viewModel.permissionDenied {
                permissionCard
            }

            // Layer 2: Annotations
            annotationLayer

            // Layer 3: Selection rectangle (while dragging)
            if let rect = viewModel.dragRect {
                selectionRect(rect)
            }

            // Layer 4: Selected region highlight
            if let rect = viewModel.selectedRegion, viewModel.dragRect == nil {
                selectionRect(rect)
            }

            // Layer 5: Response card
            if let response = viewModel.response, let region = viewModel.selectedRegion {
                responseCard(response, near: region)
            } else if let response = viewModel.response, viewModel.selectedRegion == nil {
                // Full-screen query response — show centered
                responseCardCentered(response)
            }

            // Layer 6: Processing indicator
            if viewModel.isProcessing {
                processingIndicator
            }

            // Layer 7: Input bar at bottom
            inputBar

            // Layer 8: Instructions
            if !viewModel.isProcessing && viewModel.response == nil && viewModel.selectedRegion == nil {
                instructionsBadge
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(dragGesture)
        .onExitCommand { viewModel.onDismiss?() }
        .onKeyPress(.escape) {
            viewModel.onDismiss?()
            return .handled
        }
    }

    // MARK: - Drag Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if viewModel.dragStart == nil {
                    viewModel.dragStart = value.startLocation
                    // Clear previous results when starting a new selection
                    viewModel.selectedRegion = nil
                    viewModel.response = nil
                }
                viewModel.dragCurrent = value.location
            }
            .onEnded { value in
                let start = viewModel.dragStart ?? value.startLocation
                let end = value.location
                let rect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
                viewModel.dragStart = nil
                viewModel.dragCurrent = nil

                // Only analyze if the selection is large enough
                if rect.width > 10 && rect.height > 10 {
                    viewModel.analyzeRegion(rect)
                }
            }
    }

    // MARK: - Subviews

    private func selectionRect(_ rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.08))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private var annotationLayer: some View {
        ForEach(viewModel.annotations) { annotation in
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: annotation.color.nsColor), lineWidth: 2)
                    .frame(width: annotation.rect.width, height: annotation.rect.height)

                if annotation.type == .label {
                    Text(annotation.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: annotation.color.nsColor).opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .offset(y: -(annotation.rect.height / 2) - 14)
                }
            }
            .position(x: annotation.rect.midX, y: annotation.rect.midY)
        }
    }

    private func responseCard(_ text: String, near region: CGRect) -> some View {
        let cardY = region.maxY + 80 > (NSScreen.main?.frame.height ?? 800)
            ? region.minY - 80
            : region.maxY + 20

        return Text(text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 0.5)
            )
            .shadow(radius: 8)
            .position(x: region.midX, y: cardY)
    }

    private func responseCardCentered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: 480, alignment: .leading)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 0.5)
            )
            .shadow(radius: 8)
    }

    private var processingIndicator: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.regular)
            Text("Analyzing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var inputBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.body)

                TextField("Ask about what's on screen...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit {
                        if viewModel.selectedRegion != nil {
                            viewModel.analyzeRegion(viewModel.selectedRegion!)
                        } else {
                            viewModel.analyzeFullScreen()
                        }
                    }

                if viewModel.isProcessing {
                    ProgressView().controlSize(.small)
                } else if !viewModel.inputText.isEmpty {
                    Button(action: {
                        if viewModel.selectedRegion != nil {
                            viewModel.analyzeRegion(viewModel.selectedRegion!)
                        } else {
                            viewModel.analyzeFullScreen()
                        }
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { viewModel.onDismiss?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close overlay (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 0.5)
            )
            .shadow(radius: 4)
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
    }

    private var instructionsBadge: some View {
        VStack {
            HStack(spacing: 16) {
                instructionItem(icon: "rectangle.dashed", text: "Drag to select a region")
                instructionItem(icon: "keyboard", text: "Type a question below")
                instructionItem(icon: "escape", text: "Esc to dismiss")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
            .padding(.top, 40)
            Spacer()
        }
    }

    private func instructionItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text("Screen Recording Permission Required")
                .font(.headline)

            Text(viewModel.permissionMessage.isEmpty
                 ? "Open System Settings > Privacy & Security > Screen & System Audio Recording, enable macbot, then restart the app."
                 : viewModel.permissionMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Dismiss") { viewModel.onDismiss?() }
                    .buttonStyle(.bordered)
            }

            Text("You must restart macbot after granting permission.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
    }
}
