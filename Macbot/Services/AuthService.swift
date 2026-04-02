import Foundation
import LocalAuthentication
import AppKit

@Observable
final class AuthService {
    var isUnlocked = false
    var isAuthenticating = false
    var authError: String?

    private var lastActivity = Date()
    private let autoLockTimeout: TimeInterval = 300 // 5 minutes
    private var lockTimer: Timer?

    init() {
        startMonitoring()
    }

    // MARK: - Biometric Auth

    func authenticate() {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // No biometrics available — fall back to device password
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                // No auth available — allow access (development/testing)
                Log.app.warning("No authentication available, granting access")
                isUnlocked = true
                return
            }
            evaluatePolicy(context: context, policy: .deviceOwnerAuthentication)
            return
        }

        evaluatePolicy(context: context, policy: .deviceOwnerAuthenticationWithBiometrics)
    }

    private func evaluatePolicy(context: LAContext, policy: LAPolicy) {
        isAuthenticating = true
        authError = nil

        context.evaluatePolicy(
            policy,
            localizedReason: "Unlock Macbot to access your conversations and data"
        ) { success, error in
            DispatchQueue.main.async {
                self.isAuthenticating = false
                if success {
                    self.isUnlocked = true
                    self.lastActivity = Date()
                    self.authError = nil
                    Log.app.info("Authentication successful")
                } else {
                    self.isUnlocked = false
                    self.authError = error?.localizedDescription ?? "Authentication failed"
                    Log.app.warning("Authentication failed: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    // MARK: - Auto-Lock

    func recordActivity() {
        lastActivity = Date()
    }

    func lock() {
        isUnlocked = false
        Log.app.info("App locked")
    }

    private func startMonitoring() {
        // Check for idle timeout every 30 seconds
        lockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.isUnlocked else { return }
            if Date().timeIntervalSince(self.lastActivity) > self.autoLockTimeout {
                DispatchQueue.main.async {
                    self.lock()
                }
            }
        }

        // Lock when screen sleeps or user switches
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.lock()
        }

        // Lock when app goes to background
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Only lock after extended background (not brief window switches)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                guard let self else { return }
                if !NSApplication.shared.isActive && self.isUnlocked {
                    self.lock()
                }
            }
        }
    }

    // MARK: - Database Encryption Key

    /// Get or create a database encryption key, stored in Keychain with biometric protection.
    static func databaseKey() -> String {
        let keychainKey = "com.macbot.db.encryption"

        // Try to read existing key
        if let existing = KeychainManager.get(key: keychainKey) {
            return existing
        }

        // Generate new 256-bit key
        var keyData = Data(count: 32)
        _ = keyData.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let key = keyData.base64EncodedString()

        KeychainManager.set(key: keychainKey, value: key)
        Log.app.info("Generated new database encryption key")
        return key
    }
}
