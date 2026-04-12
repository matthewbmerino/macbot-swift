import Foundation
@preconcurrency import KeychainAccess
import LocalAuthentication

enum KeychainManager {
    // `nonisolated(unsafe)`: both `Keychain` instances are immutable
    // handles to the system Keychain; all read/write methods on
    // `KeychainAccess.Keychain` funnel into Security.framework's
    // thread-safe C API. The `let`s are set exactly once at program
    // startup and are never reassigned, so the only Sendable hazard is
    // the non-Sendable type itself — which is why we also pair this
    // with `@preconcurrency import KeychainAccess`.
    nonisolated(unsafe) private static let keychain = Keychain(service: "com.macbot")
    nonisolated(unsafe) private static let secureKeychain = Keychain(service: "com.macbot.secure")
        .accessibility(.whenPasscodeSetThisDeviceOnly, authenticationPolicy: [.biometryCurrentSet])

    // MARK: - Standard (no biometric required)

    static func set(key: String, value: String) {
        keychain[key] = value
    }

    static func get(key: String) -> String? {
        keychain[key]
    }

    static func delete(key: String) {
        try? keychain.remove(key)
    }

    // MARK: - Biometric-Protected (requires Touch ID/Face ID to read)

    static func setSecure(key: String, value: String) {
        secureKeychain[key] = value
    }

    static func getSecure(key: String) -> String? {
        try? secureKeychain.get(key)
    }

    static func deleteSecure(key: String) {
        try? secureKeychain.remove(key)
    }
}
