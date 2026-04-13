import SwiftUI

/// A personalized, time-aware empty-state greeting that makes macbot
/// feel like it knows you. Pulls the user's first name from the system,
/// adapts to time of day, and shows contextual tips.
struct SmartGreeting: View {
    @State private var greeting = ""
    @State private var tip = ""
    @State private var showGreeting = false
    @State private var showTip = false

    var body: some View {
        VStack(spacing: MacbotDS.Space.lg) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(.fill.tertiary)
                    .frame(width: 80, height: 80)
                Image(systemName: greetingIcon)
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.primary.opacity(0.3))
                    .symbolRenderingMode(.hierarchical)
            }
            .opacity(showGreeting ? 1 : 0)
            .scaleEffect(showGreeting ? 1 : 0.9)

            // Personalized greeting
            Text(greeting)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.8))
                .opacity(showGreeting ? 1 : 0)
                .offset(y: showGreeting ? 0 : 8)

            // Contextual tip
            Text(tip)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .opacity(showTip ? 1 : 0)
                .offset(y: showTip ? 0 : 4)

            // Privacy line
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("All processing happens on this Mac. Your data never leaves this device.")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
            .opacity(showTip ? 1 : 0)

            Spacer()
            Color.clear.frame(height: 80)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .onAppear { buildGreeting() }
    }

    // MARK: - Greeting Logic

    private var firstName: String {
        let full = NSFullUserName()
        let first = full.components(separatedBy: " ").first ?? full
        return first.isEmpty ? "there" : first
    }

    private var hour: Int {
        Calendar.current.component(.hour, from: Date())
    }

    private var dayOfWeek: Int {
        Calendar.current.component(.weekday, from: Date())
    }

    private var greetingIcon: String {
        switch hour {
        case 5..<12:  "sun.max"
        case 12..<17: "sun.haze"
        case 17..<21: "moon.haze"
        default:      "moon.stars"
        }
    }

    private func buildGreeting() {
        // Time-aware greeting
        let timeGreeting: String
        switch hour {
        case 5..<12:  timeGreeting = "Good morning, \(firstName)."
        case 12..<17: timeGreeting = "Good afternoon, \(firstName)."
        case 17..<21: timeGreeting = "Good evening, \(firstName)."
        case 21..<24: timeGreeting = "Burning the midnight oil, \(firstName)?"
        default:      timeGreeting = "Late night, \(firstName)?"
        }
        greeting = timeGreeting

        // Contextual tip — rotates based on day/time for variety
        let tips = [
            "Try /director to watch me work step by step.",
            "Click the orb to chat hands-free.",
            "Use Cmd+Shift+O to overlay me on your screen.",
            "I can see what app you're using and help in context.",
            "Ask me about anything — code, research, your schedule.",
            "Try /ghost to watch me control your Mac.",
        ]
        // Pick a tip based on the current hour so it feels fresh
        // each time but isn't random (deterministic per hour).
        let index = (hour + dayOfWeek) % tips.count
        tip = tips[index]

        // Staggered entrance animation
        withAnimation(Motion.smooth.delay(0.1)) {
            showGreeting = true
        }
        withAnimation(Motion.smooth.delay(0.4)) {
            showTip = true
        }
    }
}
