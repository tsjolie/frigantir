import Foundation
import Observation
import UIKit
import UserNotifications

/// Push notifications for new Frigate review items.
///
/// Frigate can't send Apple push notifications, so a small self-hosted relay
/// (`notifier/` in this repo) watches Frigate and sends them. This app only asks
/// for permission, gets a device token from iOS, and registers it with the
/// relay over its HTTP API; the pushes themselves come from Apple.
@Observable
final class PushNotifications {
    enum Status: Equatable {
        case off
        case denied
        case registering
        case registered
        case failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .denied: "Notifications are turned off for this app in iOS Settings."
            case .registering: "Registering…"
            case .registered: "Registered with the notification server."
            case .failed(let reason): reason
            }
        }
    }

    /// Category the relay sets on review notifications; adds "Mark Reviewed".
    static let reviewCategory = "FRIGATE_REVIEW"
    static let markReviewedAction = "MARK_REVIEWED"

    private(set) var settings = NotificationSettings.load()
    private(set) var status: Status = .off
    @ObservationIgnored private var deviceToken: String?

    var apiToken: String { Keychain.password(for: Self.apiTokenAccount) ?? "" }
    private static let apiTokenAccount = "notifier-api-token"

    static func registerCategories() {
        let markReviewed = UNNotificationAction(identifier: markReviewedAction, title: "Mark Reviewed", options: [])
        let category = UNNotificationCategory(identifier: reviewCategory, actions: [markReviewed],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// At launch: device tokens can change, so re-register while enabled.
    func refreshRegistration() async {
        guard settings.isEnabled else { return }
        let authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard authorization == .authorized || authorization == .provisional else {
            status = .denied
            return
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Saves the settings, then registers with the relay (asking for permission
    /// first) or unregisters.
    func update(_ newSettings: NotificationSettings, apiToken: String) async {
        let wasEnabled = settings.isEnabled
        newSettings.save()
        settings = newSettings
        Keychain.setPassword(apiToken, for: Self.apiTokenAccount)

        guard newSettings.isEnabled else {
            if wasEnabled { await unregister() }
            status = .off
            return
        }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            status = .denied
            return
        }
        status = .registering
        if deviceToken != nil {
            await registerWithServer()
        }
        // The token arrives in `didRegister(deviceToken:)`, also on later launches.
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await registerWithServer() }
    }

    func didFailToRegister(_ error: Error) {
        status = .failed("iOS couldn't register for notifications: \(error.localizedDescription)")
    }

    /// Asks the relay to send a test notification to this device.
    func sendTest() async -> String {
        guard let client = notifierClient(), let deviceToken else {
            return "Save the settings and allow notifications first."
        }
        do {
            try await client.sendTest(token: deviceToken)
            return "Test notification sent."
        } catch {
            return error.localizedDescription
        }
    }

    private func registerWithServer() async {
        guard settings.isEnabled, let deviceToken else { return }
        guard let client = notifierClient() else {
            status = .failed("Enter the notification server's URL and API token.")
            return
        }
        status = .registering
        do {
            try await client.register(NotifierClient.Registration(
                token: deviceToken,
                environment: Self.apnsEnvironment,
                bundleID: Bundle.main.bundleIdentifier ?? "net.sjolie.frigateapp",
                deviceName: UIDevice.current.name,
                severities: settings.includeDetections ? ["alert", "detection"] : ["alert"],
                cameras: settings.cameras,
                ignoreVerified: settings.ignoreRecognizedPeople))
            status = .registered
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func unregister() async {
        guard let client = notifierClient(), let deviceToken else { return }
        try? await client.unregister(token: deviceToken)
    }

    private func notifierClient() -> NotifierClient? {
        guard let url = settings.serverURL, !apiToken.isEmpty else { return nil }
        return NotifierClient(baseURL: url, apiToken: apiToken)
    }

    /// Which APNs servers this build's tokens belong to. Builds run from Xcode
    /// carry a development provisioning profile; TestFlight and App Store builds
    /// carry none (or a distribution one) and use production.
    static var apnsEnvironment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              text.range(of: #"<key>aps-environment</key>\s*<string>development</string>"#,
                         options: .regularExpression) != nil
        else { return "production" }
        return "sandbox"
        #endif
    }
}

/// Notification preferences, stored in UserDefaults (the API token is in the Keychain).
struct NotificationSettings: Codable, Equatable {
    var isEnabled = false
    /// The relay, e.g. `https://notify.example.com`.
    var serverURL: URL?
    var includeDetections = false
    /// Cameras to notify about; empty means all.
    var cameras: [String] = []
    /// Skip alerts whose objects are all people Frigate's face recognition
    /// identified (`person-verified`). Filtered by the notification server.
    var ignoreRecognizedPeople = false

    private static let defaultsKey = "notificationSettings"

    init() {}

    /// Tolerates missing keys, so adding a setting later doesn't reset the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        serverURL = try container.decodeIfPresent(URL.self, forKey: .serverURL)
        includeDetections = try container.decodeIfPresent(Bool.self, forKey: .includeDetections) ?? false
        cameras = try container.decodeIfPresent([String].self, forKey: .cameras) ?? []
        ignoreRecognizedPeople = try container.decodeIfPresent(Bool.self, forKey: .ignoreRecognizedPeople) ?? false
    }

    static func load() -> NotificationSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(NotificationSettings.self, from: data)
        else { return NotificationSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// The relay's HTTP API (see notifier/README.md).
nonisolated struct NotifierClient: Sendable {
    struct Registration: Encodable, Sendable {
        let token: String
        let environment: String
        let bundleID: String
        let deviceName: String
        let severities: [String]
        let cameras: [String]
        let ignoreVerified: Bool

        enum CodingKeys: String, CodingKey {
            case token, environment, severities, cameras
            case bundleID = "bundle_id"
            case deviceName = "device_name"
            case ignoreVerified = "ignore_verified"
        }
    }

    struct ServerError: LocalizedError {
        let status: Int
        let reason: String?

        var errorDescription: String? {
            switch status {
            case 401: "The notification server rejected the API token."
            case 404: "The notification server doesn't know this device yet. Save the settings again."
            default: "Notification server error \(status)" + (reason.map { ": \($0)" } ?? "")
            }
        }
    }

    let baseURL: URL
    let apiToken: String
    var session: URLSession = .shared

    func register(_ registration: Registration) async throws {
        try await send("api/v1/devices", method: "POST", body: try JSONEncoder().encode(registration))
    }

    func unregister(token: String) async throws {
        try await send("api/v1/devices/\(token)", method: "DELETE")
    }

    func sendTest(token: String) async throws {
        try await send("api/v1/devices/\(token)/test", method: "POST")
    }

    private func send(_ path: String, method: String, body: Data? = nil) async throws {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw ServerError(status: http.statusCode,
                              reason: json?["reason"] as? String ?? json?["error"] as? String ?? json?["detail"] as? String)
        }
    }
}
