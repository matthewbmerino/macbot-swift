import SwiftUI

struct LockScreen: View {
    let authService: AuthService

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Macbot is Locked")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Authenticate to access your conversations and data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if authService.isAuthenticating {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Button(action: { authService.authenticate() }) {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if let error = authService.authError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Text("All data stays on this device")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .onAppear {
            // Auto-trigger biometric on appear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !authService.isUnlocked && !authService.isAuthenticating {
                    authService.authenticate()
                }
            }
        }
    }
}
