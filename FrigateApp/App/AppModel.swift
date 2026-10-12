import Foundation
import Observation

/// Top-level app state shared through the SwiftUI environment.
@Observable
final class AppModel {
    private(set) var settings = ServerSettings.load()
    private(set) var client: FrigateClient?
    private(set) var config: FrigateConfig?
    private(set) var loadError: String?
    private(set) var reviewSummary: ReviewSummary?
    /// Incremented whenever Frigate pushes a review update, so lists can reload.
    private(set) var reviewsRevision = 0
    /// Cameras with motion or moving objects; drives live dashboard previews.
    private(set) var activity = CameraActivity()
    /// Review items marked reviewed in this session. Lists hide them even if a
    /// response fetched before the change reached the server still has them.
    private(set) var locallyReviewed: Set<String> = []
    @ObservationIgnored private var summaryRequest = 0
    @ObservationIgnored private var reviewWritesInFlight = 0

    let playback = PlaybackManager()
    let events = FrigateEventStream()
    let push = PushNotifications()
    /// A review to show, e.g. from a tapped notification; the Review tab opens it.
    var reviewToOpen: String?

    var isConfigured: Bool { client != nil }

    init() {
        client = Self.makeClient(settings)
        events.onMessage { [weak self] message in
            guard let self else { return }
            // Frigate sends several messages a second (audio levels, stats);
            // only publish a change when a camera's activity actually changed.
            var activity = activity
            activity.apply(message)
            if activity != self.activity { self.activity = activity }

            guard message.topic == "reviews" else { return }
            reviewsRevision += 1
            Task { await self.refreshSummary() }
        }
    }

    func update(settings: ServerSettings, password: String?) async {
        if let password { Keychain.setPassword(password, for: settings.username) }
        settings.save()
        self.settings = settings
        playback.settings = settings
        client = Self.makeClient(settings)
        await reload()
    }

    func reload() async {
        guard let client else { return }
        do {
            config = try await client.config()
            loadError = nil
            events.connect(url: client.eventsWebSocketURL(), onUnauthorized: { try? await client.login() })
            await refreshSummary()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Marks items reviewed. Lists and the tab badge change immediately; the
    /// server request runs on its own task, so leaving a screen can't cancel it.
    func markReviewed(_ items: [ReviewItem]) {
        let pending = items.filter { !$0.hasBeenReviewed && !locallyReviewed.contains($0.id) }
        guard let client, !pending.isEmpty else { return }
        locallyReviewed.formUnion(pending.map(\.id))
        let dayAgo = Date.now.addingTimeInterval(-24 * 3600)
        let recent = pending.filter { $0.startDate > dayAgo }
        reviewSummary?.last24Hours.reviewedAlert += recent.filter { $0.severity == .alert }.count
        reviewSummary?.last24Hours.reviewedDetection += recent.filter { $0.severity == .detection }.count

        reviewWritesInFlight += 1
        Task {
            do {
                try await client.markReviewed(pending.map(\.id))
            } catch {
                // Not saved: show the items (and the count) again.
                locallyReviewed.subtract(pending.map(\.id))
            }
            reviewWritesInFlight -= 1
            reviewsRevision += 1
            await refreshSummary()
        }
    }

    /// Marks reviews known only by ID (from a notification action), waiting
    /// for the server so the app isn't suspended mid-request.
    func markReviewed(ids: [String]) async {
        guard let client, !ids.isEmpty else { return }
        locallyReviewed.formUnion(ids)
        reviewWritesInFlight += 1
        do {
            try await client.markReviewed(ids)
        } catch {
            locallyReviewed.subtract(ids)
        }
        reviewWritesInFlight -= 1
        reviewsRevision += 1
        await refreshSummary()
    }

    func open(reviewID: String) {
        reviewToOpen = reviewID
    }

    /// Reloads the Review badge counts. Responses can arrive out of order, and a
    /// count fetched while a "mark reviewed" request is still on its way is
    /// already out of date, so only the newest response, fetched after all
    /// writes finished, is applied.
    func refreshSummary() async {
        guard let client else { return }
        summaryRequest += 1
        let request = summaryRequest
        guard let summary = try? await client.reviewSummary(),
              request == summaryRequest, reviewWritesInFlight == 0 else { return }
        reviewSummary = summary
    }

    /// Cameras for a dashboard group, or all dashboard cameras when `group` is nil.
    func cameras(in group: String?) -> [CameraConfig] {
        guard let config else { return [] }
        let all = config.dashboardCameras
        guard let group, let members = config.cameraGroups?[group]?.cameras else { return all }
        return all.filter { members.contains($0.name) }
    }

    func preferredStream(for camera: CameraConfig) -> String {
        if let saved = settings.preferredStreams[camera.name], camera.liveStreams.contains(saved) {
            return saved
        }
        return camera.liveStreams.first ?? camera.name
    }

    func setPreferredStream(_ stream: String, for camera: CameraConfig) {
        var updated = settings
        updated.preferredStreams[camera.name] = stream
        updated.save()
        settings = updated
    }

    private static func makeClient(_ settings: ServerSettings) -> FrigateClient? {
        guard let baseURL = settings.baseURL else { return nil }
        let username = settings.username.isEmpty ? nil : settings.username
        return FrigateClient(baseURL: baseURL, username: username,
                             password: username.flatMap(Keychain.password(for:)))
    }
}
