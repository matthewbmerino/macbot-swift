import SwiftUI
import MarkdownUI

// MARK: - Apple-inspired Companion View

/// Design philosophy: Siri meets Dynamic Island meets Apple Intelligence.
/// No eyes, no face — just a luminous form that communicates through
/// color, motion, and shape. Premium materials, restrained palette,
/// typography-first chat panel.

struct CompanionView: View {
    @Bindable var viewModel: CompanionViewModel

    // Animation state
    @State private var breatheScale: CGFloat = 1.0
    @State private var breatheOpacity: Double = 0.5
    @State private var rotationAngle: Double = 0
    @State private var wavePhase: Double = 0
    @State private var errorPulse = false
    @State private var showBubble = false

    @FocusState private var chatFocused: Bool

    private let orbSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            // Speech bubble (above the orb, hidden when chat is open)
            if let suggestion = viewModel.suggestion, showBubble, !viewModel.isChatOpen {
                suggestionCard(suggestion)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.95)),
                        removal: .opacity
                    ))
                    .padding(.bottom, 8)
            }

            // The orb
            orbBody
                .onTapGesture { viewModel.interact() }

            // Chat panel — slides down from the orb
            if viewModel.isChatOpen {
                chatPanel
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -12)),
                        removal: .opacity.combined(with: .offset(y: -6))
                    ))
                    .padding(.top, 10)
            }
        }
        .frame(
            width: viewModel.isChatOpen ? 320 : 140,
            height: viewModel.isChatOpen ? 440 : 140
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: viewModel.isChatOpen)
        .onAppear { startAnimations() }
        .onChange(of: viewModel.mood) { _, newMood in animateMood(newMood) }
        .onChange(of: viewModel.suggestion) { _, val in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                showBubble = val != nil
            }
        }
    }

    // MARK: - The Orb

    private var orbBody: some View {
        ZStack {
            // Ambient glow — large, soft, barely there
            Circle()
                .fill(moodGradient.opacity(0.12))
                .frame(width: orbSize * 2, height: orbSize * 2)
                .blur(radius: 28)
                .scaleEffect(breatheScale * 1.1)

            // Mid glow ring
            Circle()
                .fill(moodGradient.opacity(breatheOpacity * 0.2))
                .frame(width: orbSize + 24, height: orbSize + 24)
                .blur(radius: 14)

            // Main orb body — frosted glass with mesh gradient feel
            Circle()
                .fill(
                    AngularGradient(
                        colors: moodColors,
                        center: .center,
                        startAngle: .degrees(rotationAngle),
                        endAngle: .degrees(rotationAngle + 360)
                    )
                )
                .frame(width: orbSize, height: orbSize)
                // Blur AFTER clip so the softness stays inside the circle
                .blur(radius: 8)
                // Re-clip to a slightly larger circle to contain the blur
                .clipShape(Circle().inset(by: -4))
                .frame(width: orbSize, height: orbSize)
                .overlay(
                    // Inner sphere highlight — top-left light source
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.35), .clear],
                                center: .init(x: 0.35, y: 0.3),
                                startRadius: 0,
                                endRadius: orbSize * 0.45
                            )
                        )
                )
                .overlay(
                    // Glass rim
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.4), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: moodPrimary.opacity(0.3), radius: 12, y: 4)
                .scaleEffect(breatheScale)

            // Thinking: orbiting particle
            if viewModel.mood == .thinking {
                orbitingParticle
            }

            // Error: ripple ring
            if errorPulse {
                Circle()
                    .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                    .frame(width: orbSize + 16, height: orbSize + 16)
                    .scaleEffect(errorPulse ? 1.4 : 1.0)
                    .opacity(errorPulse ? 0 : 1)
            }
        }
    }

    private var orbitingParticle: some View {
        Circle()
            .fill(.white.opacity(0.8))
            .frame(width: 4, height: 4)
            .offset(x: orbSize * 0.42)
            .rotationEffect(.degrees(rotationAngle * 2))
            .blur(radius: 0.5)
    }

    // MARK: - Suggestion Card

    private func suggestionCard(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(moodPrimary.opacity(0.6))
                .frame(width: 6, height: 6)

            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 280)
    }

    // MARK: - Chat Panel

    private var chatPanel: some View {
        VStack(spacing: 0) {
            // Context strip — minimal, monospaced
            if !viewModel.currentContext.isEmpty {
                contextStrip
                    .padding(.bottom, 10)
            }

            // Response
            if let response = viewModel.chatResponse {
                ScrollView {
                    Markdown(response)
                        .markdownTextStyle {
                            FontSize(12.5)
                            FontFamily(.system(.rounded))
                            ForegroundColor(.primary.opacity(0.8))
                        }
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            configuration.label
                                .padding(8)
                                .background(.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                                )
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .frame(maxHeight: 140)
                .padding(.bottom, 10)
            }

            // Input
            inputBar
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        )
        .onAppear { chatFocused = true }
    }

    private var contextStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(moodPrimary.opacity(0.6))

            Text(viewModel.currentContext.replacingOccurrences(of: "\n", with: " · "))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.1).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything...", text: $viewModel.chatInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .focused($chatFocused)
                .onSubmit { viewModel.sendChat() }
                .disabled(viewModel.isResponding)

            if viewModel.isResponding {
                // Apple-style indeterminate spinner
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else {
                Button(action: { viewModel.sendChat() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(
                            viewModel.chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                            ? .white.opacity(0.1) : moodPrimary
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.white.opacity(0.1).opacity(0.4))
        )
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.1).opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Mood Colors

    /// Apple-inspired palette — muted, sophisticated, never garish.
    private var moodPrimary: Color {
        switch viewModel.mood {
        case .idle:      Color(red: 0.35, green: 0.65, blue: 0.95)   // soft blue
        case .listening: Color(red: 0.4,  green: 0.55, blue: 1.0)    // brighter blue
        case .thinking:  Color(red: 0.6,  green: 0.45, blue: 0.95)   // lavender
        case .excited:   Color(red: 0.95, green: 0.6,  blue: 0.3)    // warm amber
        case .sleeping:  Color(red: 0.45, green: 0.45, blue: 0.5)    // muted gray
        case .error:     Color(red: 0.95, green: 0.35, blue: 0.35)   // soft red
        }
    }

    private var moodSecondary: Color {
        switch viewModel.mood {
        case .idle:      Color(red: 0.3,  green: 0.85, blue: 0.85)   // teal accent
        case .listening: Color(red: 0.55, green: 0.4,  blue: 0.95)   // indigo
        case .thinking:  Color(red: 0.85, green: 0.35, blue: 0.7)    // magenta
        case .excited:   Color(red: 1.0,  green: 0.4,  blue: 0.5)    // coral
        case .sleeping:  Color(red: 0.35, green: 0.35, blue: 0.45)    // darker gray
        case .error:     Color(red: 0.85, green: 0.2,  blue: 0.4)    // deeper red
        }
    }

    private var moodColors: [Color] {
        [moodPrimary, moodSecondary, moodPrimary.opacity(0.7), moodSecondary.opacity(0.8)]
    }

    private var moodGradient: RadialGradient {
        RadialGradient(
            colors: [moodPrimary, moodSecondary.opacity(0.5)],
            center: .center,
            startRadius: 0,
            endRadius: orbSize
        )
    }

    // MARK: - Animations

    private func startAnimations() {
        // Breathing — subtle scale + opacity
        withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
            breatheScale = 1.04
        }
        withAnimation(.easeInOut(duration: 4.0).repeatForever(autoreverses: true)) {
            breatheOpacity = 0.7
        }
        // Slow color rotation — the orb is always subtly alive
        withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
            rotationAngle = 360
        }
        animateMood(viewModel.mood)
    }

    private func animateMood(_ mood: CompanionMood) {
        // Thinking: speed up rotation
        if mood == .thinking {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                rotationAngle += 360
            }
        }

        // Excited: gentle bounce
        if mood == .excited {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45).repeatCount(3)) {
                breatheScale = 1.12
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.spring(response: 0.5)) { breatheScale = 1.04 }
            }
        }

        // Error: ripple out
        if mood == .error {
            withAnimation(.easeOut(duration: 0.6)) {
                errorPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                errorPulse = false
            }
        }
    }
}
