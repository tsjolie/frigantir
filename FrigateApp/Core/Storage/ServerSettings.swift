import Foundation
import Security

/// Connection settings, persisted in UserDefaults. The password lives in the Keychain.
struct ServerSettings: Codable, Equatable, Sendable {
    /// Frigate's authenticated UI/API port (8971) or a reverse proxy in front of it,
    /// e.g. `https://frigate.example.com`.
    var baseURL: URL?
    var username: String = ""
    /// Reconnect in audio-only mode after the app has been in the background
    /// without PiP for this long. `nil` keeps the full stream (video decoding is
    /// paused either way; this also stops the video bytes being downloaded).
    var audioOnlyAfterBackgroundSeconds: TimeInterval? = 10
    /// Keep a camera's audio playing after leaving its screen (baby-monitor mode).
    var keepAudioWhenLeavingCamera = true
    /// Preferred go2rtc stream per camera, when `live.streams` offers several
    /// (e.g. a low-resolution substream for mobile).
    var preferredStreams: [String: String] = [:]

    private static let defaultsKey = "serverSettings"

    static func load() -> ServerSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ServerSettings.self, from: data)
        else { return ServerSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Minimal Keychain wrapper for the Frigate password.
enum Keychain {
    private static let service = "net.sjolie.frigateapp"

    static func password(for account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData] = Data(password.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
