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
    @State private var cursorDistance: CGFloat = 1.0
    @State private var cursorAngle: CGFloat = 0.0

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
                    .padding(.bottom, MacbotDS.Space.sm)
            }

            // The orb
            orbBody
                .onTapGesture { viewModel.interact() }
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .help("Click to chat with macbot")
                .accessibilityLabel("macbot companion")
                .accessibilityHint("Click to open chat")

            // Chat panel — slides down from the orb
            if viewModel.isChatOpen {
                chatPanel
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -12)),
                        removal: .opacity.combined(with: .offset(y: -6))
                    ))
                    .padding(.top, MacbotDS.Space.sm)
            }
        }
        .frame(
            width: viewModel.isChatOpen ? 320 : 140,
            height: viewModel.isChatOpen ? 440 : 140
        )
        .animation(Motion.smooth, value: viewModel.isChatOpen)
        .onAppear { startAnimations() }
        .onChange(of: viewModel.mood) { _, newMood in animateMood(newMood) }
        .onChange(of: viewModel.suggestion) { _, val in
            withAnimation(Motion.gentle) {
                showBubble = val != nil
            }
        }
    }

    // MARK: - The Orb

    private var orbBody: some View {
        let shaderSize = orbSize * 2  // shader quad needs room for the outer glow
        return ZStack {
            // Ambient glow — large, soft, barely there (view-level, not shader)
            Circle()
                .fill(moodGradient.opacity(0.12))
                .frame(width: orbSize * 2, height: orbSize * 2)
                .blur(radius: 28)
                .scaleEffect(breatheScale * 1.1)

            // Mid glow ring (view-level ambient light)
            Circle()
                .fill(moodGradient.opacity(breatheOpacity * 0.2))
                .frame(width: orbSize + 24, height: orbSize + 24)
                .blur(radius: 14)

            // Metal SDF orb — the hero visual
            OrbShaderView(
                mood: viewModel.mood,
                cursorDistance: cursorDistance,
                cursorAngle: cursorAngle,
                size: shaderSize
            )
            .shadow(color: moodPrimary.opacity(0.3), radius: 12, y: 4)
            .scaleEffect(breatheScale)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let center = CGPoint(x: shaderSize / 2, y: shaderSize / 2)
                    let dx = Float(location.x - center.x)
                    let dy = Float(location.y - center.y)
                    cursorDistance = CGFloat(min(sqrt(dx * dx + dy * dy) / Float(shaderSize * 0.5), 1.0))
                    cursorAngle = CGFloat(atan2(dy, dx))
                case .ended:
                    withAnimation(.easeOut(duration: 0.4)) {
                        cursorDistance = 1.0
                    }
                }
            }

            // Error: ripple ring
            if errorPulse {
                Circle()
                    .stroke(MacbotDS.Colors.danger.opacity(0.6), lineWidth: 1.5)
                    .frame(width: orbSize + 16, height: orbSize + 16)
                    .scaleEffect(errorPulse ? 1.4 : 1.0)
                    .opacity(errorPulse ? 0 : 1)
            }
        }
    }

    // MARK: - Suggestion Card

    private func suggestionCard(_ text: String) -> some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Circle()
                .fill(moodPrimary.opacity(0.6))
                .frame(width: 6, height: 6)

            Text(text)
                .font(MacbotDS.Typo.caption)
                .foregroundStyle(MacbotDS.Colors.textPri.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(MacbotDS.Mat.float)
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacbotDS.Radius.lg, style: .continuous)
                .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .frame(maxWidth: 280)
    }

    // MARK: - Chat Panel

    private var chatPanel: some View {
        VStack(spacing: 0) {
            // Close button — top-right
            HStack {
                Spacer()
                Button(action: { viewModel.closeChat() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close chat")
            }
            .padding(.bottom, MacbotDS.Space.xs)

            // Context strip — minimal, monospaced
            if !viewModel.currentContext.isEmpty {
                contextStrip
                    .padding(.bottom, MacbotDS.Space.sm)
            }

            // Response
            if let response = viewModel.chatResponse {
                ScrollView {
                    Markdown(response)
                        .markdownTextStyle {
                            FontSize(13)
                            FontFamily(.system(.rounded))
                            ForegroundColor(.primary.opacity(0.8))
                        }
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            configuration.label
                                .padding(MacbotDS.Space.sm)
                                .background(.fill.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                                        .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
                                )
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .frame(maxHeight: 140)
                .padding(.bottom, MacbotDS.Space.sm)
            }

            // Input
            inputBar
        }
        .padding(MacbotDS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(MacbotDS.Mat.float)
                .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
        )
        .onAppear { chatFocused = true }
        .onExitCommand { viewModel.closeChat() }
    }

    private var contextStrip: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: "eye")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(moodPrimary.opacity(0.6))

            Text(viewModel.currentContext.replacingOccurrences(of: "\n", with: " · "))
                .font(MacbotDS.Typo.mono)
                .foregroundStyle(MacbotDS.Colors.textSec.opacity(0.5))
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MacbotDS.Space.sm)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(.fill.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
    }

    private var inputBar: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            TextField("Ask anything...", text: $viewModel.chatInput)
                .textFieldStyle(.plain)
                .font(MacbotDS.Typo.body)
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
                        .font(.title2)
                        .foregroundStyle(
                            viewModel.chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                            ? MacbotDS.Colors.textTer.opacity(0.3) : moodPrimary
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.chatInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(
            Capsule()
                .fill(.fill.quaternary)
        )
        .overlay(
            Capsule()
                .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
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
        // Breathing — phase-offset springs so scale & opacity never lock in sync
        withAnimation(Motion.gentle.repeatForever(autoreverses: true)) {
            breatheScale = 1.04
        }
        withAnimation(Motion.gentle.speed(0.85).repeatForever(autoreverses: true)) {
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

        // Excited: bouncy overshoot
        if mood == .excited {
            withAnimation(Motion.lively.repeatCount(3)) {
                breatheScale = 1.12
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(Motion.smooth) { breatheScale = 1.04 }
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
