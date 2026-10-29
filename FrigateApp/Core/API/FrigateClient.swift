import Foundation

/// Async client for the Frigate HTTP API, plus URL builders for media
/// (snapshots, thumbnails, HLS recordings, live WebSocket streams).
///
/// With Frigate auth enabled, `login` stores the `frigate_token` JWT cookie in
/// the shared cookie store; URLSession then sends it on every request, including
/// the live-stream WebSockets and AsyncImage loads.
nonisolated struct FrigateClient: Sendable {
    enum ClientError: LocalizedError {
        case http(Int, String)
        /// An error status with Frigate's own explanation (`{"message": …}`).
        case server(Int, String)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .http(let code, let path): "HTTP \(code) for \(path)"
            case .server(_, let message): message
            case .unauthorized: "Frigate rejected the credentials"
            }
        }
    }

    let baseURL: URL
    var username: String?
    var password: String?
    var session: URLSession = .shared

    // MARK: - API

    func config() async throws -> FrigateConfig {
        try await get("api/config")
    }

    /// Without `after`, Frigate only returns items that ended in the last 24 hours.
    func reviews(severity: ReviewItem.Severity? = nil, reviewed: Bool = false,
                 cameras: [String]? = nil, after: Date? = nil, before: Date? = nil,
                 limit: Int = 50) async throws -> [ReviewItem] {
        var query = [URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "reviewed", value: reviewed ? "1" : "0")]
        if let severity { query.append(URLQueryItem(name: "severity", value: severity.rawValue)) }
        if let cameras { query.append(URLQueryItem(name: "cameras", value: cameras.joined(separator: ","))) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after.timeIntervalSince1970))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before.timeIntervalSince1970))) }
        return try await get("api/review", query: query)
    }

    /// Every unreviewed item of a severity, of any age, newest first, fetched
    /// a page at a time (the list screen only has the first page or two).
    func allUnreviewedReviews(severity: ReviewItem.Severity, pageSize: Int = 500) async throws -> [ReviewItem] {
        var all: [ReviewItem] = []
        var seen: Set<String> = []
        var before: Date?
        while true {
            // An explicit `after` lifts Frigate's 24-hour default. Not 0: Frigate
            // reads it with Python's `or`, which treats 0 as missing.
            let page = try await reviews(severity: severity, after: Date(timeIntervalSince1970: 1),
                                         before: before, limit: pageSize)
            // `before` is exclusive in theory, but items can share a start time; stop
            // once a page brings nothing new so a repeat can't loop forever.
            let new = page.filter { seen.insert($0.id).inserted }
            all += new
            guard page.count == pageSize, !new.isEmpty, let last = page.last else { return all }
            before = last.startDate
        }
    }

    /// Every review item on one camera that overlaps a time range, reviewed or
    /// not. Frigate filters on one review state per request, so ask for both.
    func reviews(camera: String, after: Date, before: Date) async throws -> [ReviewItem] {
        @Sendable func page(reviewed: Bool) async throws -> [ReviewItem] {
            try await get("api/review", query: [
                URLQueryItem(name: "cameras", value: camera),
                URLQueryItem(name: "after", value: String(after.timeIntervalSince1970)),
                URLQueryItem(name: "before", value: String(before.timeIntervalSince1970)),
                URLQueryItem(name: "reviewed", value: reviewed ? "1" : "0"),
                URLQueryItem(name: "limit", value: "1000"),
            ])
        }
        async let unreviewed = page(reviewed: false)
        async let reviewed = page(reviewed: true)
        return try await (unreviewed + reviewed).sorted { $0.startTime < $1.startTime }
    }

    /// One review item, e.g. the one a notification is about.
    func review(id: String) async throws -> ReviewItem {
        try await get("api/review/\(id)")
    }

    func reviewSummary() async throws -> ReviewSummary {
        try await get("api/review/summary", query: [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)])
    }

    /// Marks reviews viewed, in batches so a big backlog doesn't make one huge request.
    func markReviewed(_ ids: [String]) async throws {
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = Array(ids[start ..< min(start + 500, ids.count)])
            _ = try await send("api/reviews/viewed", method: "POST", json: ["ids": batch])
        }
    }

    func trackedObjects(camera: String? = nil, label: String? = nil, before: Date? = nil,
                        limit: Int = 50) async throws -> [TrackedObject] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let camera { query.append(URLQueryItem(name: "cameras", value: camera)) }
        if let label { query.append(URLQueryItem(name: "labels", value: label)) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before.timeIntervalSince1970))) }
        return try await get("api/events", query: query)
    }

    /// Motion level per `bucket` seconds, for the History timeline.
    func motionActivity(camera: String, after: Date, before: Date, bucket: Int = 30) async throws -> [MotionActivity] {
        try await get("api/review/activity/motion", query: [
            URLQueryItem(name: "cameras", value: camera),
            URLQueryItem(name: "after", value: String(Int(after.timeIntervalSince1970))),
            URLQueryItem(name: "before", value: String(Int(before.timeIntervalSince1970))),
            URLQueryItem(name: "scale", value: String(bucket)),
        ])
    }

    /// The recording segments stored for a time range; needed to map wall-clock
    /// time onto a `/vod` playlist, which leaves out the gaps between them.
    func recordings(camera: String, after: Date, before: Date) async throws -> [RecordingSegment] {
        try await get("api/\(camera)/recordings", query: [
            URLQueryItem(name: "after", value: String(Int(after.timeIntervalSince1970))),
            URLQueryItem(name: "before", value: String(Int(before.timeIntervalSince1970))),
        ])
    }

    /// Starts saving a span of recordings as an MP4 on the server; it shows up
    /// on the Frigate web UI's Exports page once it's done.
    func exportRecording(camera: String, start: Date, end: Date, name: String?) async throws {
        var body: [String: Any] = ["playback": "realtime", "source": "recordings"]
        if let name, !name.isEmpty { body["name"] = name }
        let path = "api/export/\(camera)/start/\(Int(start.timeIntervalSince1970))/end/\(Int(end.timeIntervalSince1970.rounded(.up)))"
        _ = try await send(path, method: "POST", json: body)
    }

    /// Exports saved on the server, newest first.
    func exports() async throws -> [FrigateExport] {
        let exports: [FrigateExport] = try await get("api/exports")
        return exports.sorted { $0.date > $1.date }
    }

    func deleteExport(id: String) async throws {
        _ = try await send("api/export/\(id)", method: "DELETE", json: nil)
    }

    func stats() async throws -> FrigateStats {
        try await get("api/stats")
    }

    /// Frigate ≥ 0.14 auth: exchanges credentials for a `frigate_token` cookie.
    func login() async throws {
        guard let username, let password, !username.isEmpty else { throw ClientError.unauthorized }
        let (_, response) = try await send("api/login", method: "POST",
                                           json: ["user": username, "password": password], retryAuth: false)
        guard (200 ..< 300).contains(response.statusCode) else { throw ClientError.unauthorized }
    }

    // MARK: - Media URLs

    /// Latest frame, scaled server-side so the dashboard grid stays cheap.
    func latestFrameURL(camera: String, height: Int = 360, cacheBust: Date = .now) -> URL {
        url("api/\(camera)/latest.webp", query: [
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "cache", value: String(Int(cacheBust.timeIntervalSince1970))),
        ])
    }

    /// Review thumbnails are files under /media/frigate/clips, served at /clips.
    func reviewThumbnailURL(_ item: ReviewItem) -> URL {
        mediaURL(item.thumbPath)
    }

    /// Export files live under /media/frigate/exports, served at /exports.
    func exportVideoURL(_ export: FrigateExport) -> URL {
        mediaURL(export.videoPath)
    }

    func exportThumbnailURL(_ export: FrigateExport) -> URL? {
        export.thumbPath.map(mediaURL)
    }

    /// Frigate's nginx serves the files under /media/frigate from the root.
    private func mediaURL(_ path: String) -> URL {
        url(path.replacingOccurrences(of: "/media/frigate/", with: ""))
    }

    func snapshotURL(_ object: TrackedObject) -> URL {
        url("api/events/\(object.id)/snapshot.jpg", query: [URLQueryItem(name: "bbox", value: "1")])
    }

    func thumbnailURL(_ object: TrackedObject) -> URL {
        url("api/events/\(object.id)/thumbnail.webp")
    }

    /// HLS playlist of recordings for a time range, served by Frigate's nginx-vod
    /// module. AVPlayer plays it natively (hardware decode, PiP, AirPlay).
    func recordingPlaylistURL(camera: String, start: Date, end: Date) -> URL {
        url("vod/\(camera)/start/\(Int(start.timeIntervalSince1970))/end/\(Int(end.timeIntervalSince1970))/index.m3u8")
    }

    func reviewPlaylistURL(_ item: ReviewItem) -> URL {
        let end = item.endTime.map(Date.init(timeIntervalSince1970:)) ?? .now
        return recordingPlaylistURL(camera: item.camera,
                                    start: item.startDate.addingTimeInterval(-4),
                                    end: end.addingTimeInterval(4))
    }

    /// go2rtc's MSE WebSocket, proxied by Frigate's nginx at /live/mse.
    func liveStreamRequest(stream: String) -> URLRequest {
        URLRequest(url: webSocketURL("live/mse/api/ws", query: [URLQueryItem(name: "src", value: stream)]))
    }

    /// Frigate's own WebSocket (review/event/activity updates).
    func eventsWebSocketURL() -> URL {
        webSocketURL("ws", query: [])
    }

    // MARK: - Plumbing

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func webSocketURL(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: url(path, query: query), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: url(path, query: query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await perform(request, retryAuth: true)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String, json: [String: Any]?,
                      retryAuth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await perform(request, retryAuth: retryAuth)
    }

    /// Performs a request; on 401 with stored credentials, logs in once and retries.
    private func perform(_ request: URLRequest, retryAuth: Bool) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401, retryAuth, username?.isEmpty == false {
            try await login()
            return try await perform(request, retryAuth: false)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ClientError.unauthorized }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? String, !message.isEmpty {
                throw ClientError.server(http.statusCode, message)
            }
            throw ClientError.http(http.statusCode, request.url?.path ?? "")
        }
        return (data, http)
    }
}
