import Foundation
import KeychainAccess
import LocalAuthentication

enum KeychainManager {
    private static let keychain = Keychain(service: "com.macbot")
    private static let secureKeychain = Keychain(service: "com.macbot.secure")
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
