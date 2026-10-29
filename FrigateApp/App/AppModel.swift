import Foundation
import Observation
import SwiftUI

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
    @ObservationIgnored private var pendingSummaryRefresh: Task<Void, Never>?

    let playback = PlaybackManager()
    let events = FrigateEventStream()
    let push = PushNotifications()
    /// The review a tapped notification is about. RootView shows it full screen
    /// over whatever is on screen until it's closed.
    private(set) var presentedReviewID: String?

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
            scheduleSummaryRefresh()
        }
    }

    /// Frigate sends a review update every few seconds while an event is in
    /// progress; refresh the badge once things are quiet for a second, not
    /// for every message.
    private func scheduleSummaryRefresh() {
        pendingSummaryRefresh?.cancel()
        pendingSummaryRefresh = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await refreshSummary()
        }
    }

    /// The event WebSocket only matters on screen (badge, lists, dashboard
    /// activity). In the background, e.g. while a camera's audio plays, it
    /// would keep the app parsing messages nobody sees, so it closes; back in
    /// the foreground it reconnects at once and everything catches up.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            pendingSummaryRefresh?.cancel()
            events.disconnect()
        case .active:
            guard let client else { return }
            // Never reached the server (say, launched offline): try again now.
            guard config != nil else {
                Task { await reload() }
                return
            }
            if !events.isRunning { connectEvents(client) }
            reviewsRevision += 1 // lists reload what changed meanwhile
            Task { await refreshSummary() }
        default:
            break
        }
    }

    private func connectEvents(_ client: FrigateClient) {
        events.connect(url: client.eventsWebSocketURL(), onUnauthorized: { try? await client.login() })
    }

    /// Saves new connection settings and reconnects. With `requireConnection`
    /// (first launch), nothing is saved unless Frigate answers with these
    /// settings, so the Connect screen stays up and shows why instead of
    /// opening the app on a server it can't reach. Returns whether it saved.
    @discardableResult
    func update(settings: ServerSettings, password: String?, requireConnection: Bool = false) async -> Bool {
        if requireConnection {
            loadError = nil
            guard let candidate = Self.makeClient(settings, password: password) else { return false }
            do {
                _ = try await candidate.config()
            } catch {
                loadError = Self.connectionMessage(for: error)
                return false
            }
        }
        if let password { Keychain.setPassword(password, for: settings.username) }
        settings.save()
        self.settings = settings
        playback.settings = settings
        client = Self.makeClient(settings)
        await reload()
        return true
    }

    /// Plain-language reasons a server address didn't work.
    private static func connectionMessage(for error: Error) -> String {
        if error is DecodingError {
            return "That address answered, but not like a Frigate server. Check the address and port (Frigate uses 8971)."
        }
        if let error = error as? URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "Couldn't find that server. Check the address."
            case .cannotConnectToHost, .timedOut, .networkConnectionLost:
                return "Couldn't connect to that server. Check the address and port, and that Frigate is running."
            case .notConnectedToInternet:
                return "This device isn't connected to the internet."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return """
                    The server's HTTPS certificate isn't trusted. Use an address with a valid certificate, \
                    or http:// on your local network.
                    """
            default:
                break
            }
        }
        return error.localizedDescription
    }

    func reload() async {
        guard let client else { return }
        do {
            config = try await client.config()
            loadError = nil
            connectEvents(client)
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

    /// Marks every unreviewed item of a severity reviewed, not just the ones a
    /// list has loaded, and clears that part of the badge right away. Returns
    /// an error message if it couldn't.
    func markAllReviewed(severity: ReviewItem.Severity) async -> String? {
        guard let client else { return nil }
        // Counts fetched until the writes finish are out of date; see refreshSummary.
        reviewWritesInFlight += 1
        let ids: [String]
        do {
            ids = try await client.allUnreviewedReviews(severity: severity).map(\.id)
        } catch {
            reviewWritesInFlight -= 1
            return error.localizedDescription
        }
        let newlyHidden = Set(ids).subtracting(locallyReviewed)
        locallyReviewed.formUnion(newlyHidden)
        let savedSummary = reviewSummary
        // One mutation: reading reviewSummary while assigning into it is an
        // exclusivity violation (the @Observable modify accessor holds access).
        reviewSummary?.last24Hours.markAllReviewed(severity)

        // Its own task, so leaving the screen can't cancel the request.
        let failure = await Task {
            do {
                try await client.markReviewed(ids)
                return nil as String?
            } catch {
                return error.localizedDescription
            }
        }.value
        if failure != nil {
            // Not (all) saved: show the items and the count again; the reload
            // below brings back the true state of any batches that did save.
            locallyReviewed.subtract(newlyHidden)
            reviewSummary = savedSummary
        }
        reviewWritesInFlight -= 1
        reviewsRevision += 1
        await refreshSummary()
        return failure
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

    /// Shows a review (from a notification) over everything else. A newer one
    /// replaces it.
    func open(reviewID: String) {
        presentedReviewID = reviewID
    }

    func closeReview() {
        presentedReviewID = nil
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

    /// `password` overrides the one saved in the Keychain for the username.
    private static func makeClient(_ settings: ServerSettings, password: String? = nil) -> FrigateClient? {
        guard let baseURL = settings.baseURL else { return nil }
        let username = settings.username.isEmpty ? nil : settings.username
        return FrigateClient(baseURL: baseURL, username: username,
                             password: password ?? username.flatMap(Keychain.password(for:)))
    }
}
