import SwiftUI

/// Narration panel shown during ghost cursor sessions.
/// Semi-transparent dark panel at bottom-center of screen with step info,
/// progress bar, and cancel button.
struct GhostCursorView: View {
    @Bindable var viewModel: GhostCursorViewModel

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(.purple)
                Text("Ghost Cursor")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if viewModel.isRunning {
                    Button(action: { viewModel.cancel() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel (Esc)")
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }

            // Current step narration
            Text(viewModel.narration.isEmpty ? "Preparing..." : viewModel.narration)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Progress bar
            ProgressView(value: viewModel.progress)
                .tint(.purple)

            // Step counter
            if !viewModel.steps.isEmpty {
                Text(viewModel.currentStepLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.75))
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}
