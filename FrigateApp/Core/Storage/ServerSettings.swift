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

extension URL {
    /// Parses a server address as typed: `frigate.example.com`,
    /// `192.168.1.10:8971/frigate` or a full `http(s)://` URL. A missing scheme
    /// means HTTPS. `nil` if it isn't a usable web address.
    nonisolated static func serverAddress(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) == nil {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        // Paths are appended to the base URL; a trailing slash would double up.
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
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
