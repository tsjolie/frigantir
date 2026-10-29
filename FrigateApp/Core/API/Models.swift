import Foundation

// Codable mirrors of the Frigate HTTP API (verified against Frigate 0.18).
// Only fields the app uses are declared; unknown keys are ignored by JSONDecoder.
// Keys are mapped explicitly rather than with `.convertFromSnakeCase`, because that
// strategy also rewrites dictionary keys such as camera names ("front_door").
// Models are `nonisolated` (the target defaults to MainActor isolation) so they
// can be decoded and passed around off the main thread.

nonisolated struct FrigateConfig: Decodable, Sendable {
    let cameras: [String: CameraConfig]
    let cameraGroups: [String: CameraGroup]?

    enum CodingKeys: String, CodingKey {
        case cameras
        case cameraGroups = "camera_groups"
    }

    /// Enabled cameras shown on the dashboard, in the order Frigate's UI uses.
    var dashboardCameras: [CameraConfig] {
        cameras.values
            .filter { $0.enabled && ($0.ui?.dashboard ?? true) }
            .sorted { ($0.ui?.order ?? 0, $0.name) < ($1.ui?.order ?? 0, $1.name) }
    }

    /// Camera group names in the order Frigate's UI shows them.
    var sortedGroupNames: [String] {
        (cameraGroups ?? [:])
            .sorted { ($0.value.order ?? 0, $0.key) < ($1.value.order ?? 0, $1.key) }
            .map(\.key)
    }
}

nonisolated struct CameraConfig: Decodable, Sendable, Identifiable, Hashable {
    let name: String
    let enabled: Bool
    let live: LiveConfig?
    let ui: UIConfig?
    let detect: DetectConfig?

    var id: String { name }

    struct LiveConfig: Decodable, Sendable, Hashable {
        /// Display name → go2rtc stream name. Lets a camera expose e.g. a
        /// low-resolution substream for mobile alongside the main stream.
        let streams: [String: String]?
    }

    struct UIConfig: Decodable, Sendable, Hashable {
        let order: Int?
        let dashboard: Bool?
    }

    struct DetectConfig: Decodable, Sendable, Hashable {
        let width: Int?
        let height: Int?
    }

    /// go2rtc stream names for this camera; Frigate defaults to the camera name.
    var liveStreams: [String] {
        let streams = live?.streams?.values.sorted() ?? []
        return streams.isEmpty ? [name] : streams
    }

    var aspectRatio: Double {
        guard let w = detect?.width, let h = detect?.height, h > 0 else { return 16 / 9 }
        return Double(w) / Double(h)
    }
}

nonisolated struct CameraGroup: Decodable, Sendable, Hashable {
    let cameras: [String]
    let icon: String?
    let order: Int?
}

/// An item on the Review page (`/api/review`): a span of activity rated
/// `alert` or `detection`.
nonisolated struct ReviewItem: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let camera: String
    let startTime: Double
    let endTime: Double?
    let severity: Severity
    let thumbPath: String
    let data: ReviewData
    let hasBeenReviewed: Bool

    enum CodingKeys: String, CodingKey {
        case id, camera, severity, data
        case startTime = "start_time"
        case endTime = "end_time"
        case thumbPath = "thumb_path"
        case hasBeenReviewed = "has_been_reviewed"
    }

    enum Severity: String, Decodable, Sendable, CaseIterable {
        case alert, detection
    }

    struct ReviewData: Decodable, Sendable, Hashable {
        let objects: [String]
        let subLabels: [String]?
        let zones: [String]
        let audio: [String]
        let detections: [String]

        enum CodingKeys: String, CodingKey {
            case objects, zones, audio, detections
            case subLabels = "sub_labels"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        camera = try container.decode(String.self, forKey: .camera)
        startTime = try container.decode(Double.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Double.self, forKey: .endTime)
        severity = try container.decode(Severity.self, forKey: .severity)
        thumbPath = try container.decode(String.self, forKey: .thumbPath)
        data = try container.decode(ReviewData.self, forKey: .data)
        // `/api/review/<id>` leaves this out (review state is per user).
        hasBeenReviewed = try container.decodeIfPresent(Bool.self, forKey: .hasBeenReviewed) ?? false
    }

    var startDate: Date { Date(timeIntervalSince1970: startTime) }
    var isInProgress: Bool { endTime == nil }
    var labels: [String] { data.objects + data.audio }
}

/// A tracked object (`/api/events`), shown on the Explore page.
nonisolated struct TrackedObject: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let camera: String
    let label: String
    let subLabel: String?
    let zones: [String]
    let startTime: Double
    let endTime: Double?
    let hasClip: Bool
    let hasSnapshot: Bool
    let data: ObjectData?

    enum CodingKeys: String, CodingKey {
        case id, camera, label, zones, data
        case subLabel = "sub_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case hasClip = "has_clip"
        case hasSnapshot = "has_snapshot"
    }

    struct ObjectData: Decodable, Sendable, Hashable {
        let score: Double?
        let topScore: Double?

        enum CodingKeys: String, CodingKey {
            case score
            case topScore = "top_score"
        }
    }

    var startDate: Date { Date(timeIntervalSince1970: startTime) }
}

/// `/api/exports`: a span of recordings Frigate saved as an MP4.
nonisolated struct FrigateExport: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let camera: String
    let name: String
    let date: Double
    let videoPath: String
    let thumbPath: String?
    let inProgress: Bool

    enum CodingKeys: String, CodingKey {
        case id, camera, name, date
        case videoPath = "video_path"
        case thumbPath = "thumb_path"
        case inProgress = "in_progress"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        camera = try container.decode(String.self, forKey: .camera)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        date = try container.decodeIfPresent(Double.self, forKey: .date) ?? 0
        videoPath = try container.decode(String.self, forKey: .videoPath)
        thumbPath = try container.decodeIfPresent(String.self, forKey: .thumbPath)
        inProgress = try container.decodeIfPresent(Bool.self, forKey: .inProgress) ?? false
    }

    var createdDate: Date { Date(timeIntervalSince1970: date) }
    var displayName: String { name.isEmpty ? camera.cameraDisplayName : name }

    /// A name for the downloaded file: the export's name, made safe for a path.
    var fileName: String {
        let base = displayName.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let ext = (videoPath as NSString).pathExtension
        return base.trimmingCharacters(in: .whitespaces) + "." + (ext.isEmpty ? "mp4" : ext)
    }
}

/// `/api/review/summary`: counts keyed by `last24Hours` and by `yyyy-MM-dd`.
nonisolated struct ReviewSummary: Decodable, Sendable {
    var last24Hours: DayCounts

    struct DayCounts: Decodable, Sendable {
        var reviewedAlert: Int
        var reviewedDetection: Int
        let totalAlert: Int
        let totalDetection: Int

        enum CodingKeys: String, CodingKey {
            case reviewedAlert = "reviewed_alert"
            case reviewedDetection = "reviewed_detection"
            case totalAlert = "total_alert"
            case totalDetection = "total_detection"
        }

        mutating func markAllReviewed(_ severity: ReviewItem.Severity) {
            switch severity {
            case .alert: reviewedAlert = totalAlert
            case .detection: reviewedDetection = totalDetection
            }
        }

        var unreviewedAlerts: Int { totalAlert - reviewedAlert }
        var unreviewedDetections: Int { totalDetection - reviewedDetection }
    }
}

/// `/api/review/activity/motion`: average motion in one time bucket, 0–100.
nonisolated struct MotionActivity: Decodable, Sendable, Hashable {
    let startTime: Double
    let motion: Double

    enum CodingKeys: String, CodingKey {
        case motion
        case startTime = "start_time"
    }
}

/// `/api/<camera>/recordings`: one stored recording segment (about 10 s).
nonisolated struct RecordingSegment: Decodable, Sendable, Hashable {
    let startTime: Double
    let endTime: Double

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

/// `/api/stats`, trimmed to what the System page shows.
nonisolated struct FrigateStats: Decodable, Sendable {
    let cameras: [String: CameraStats]
    let detectors: [String: DetectorStats]
    let service: Service

    struct CameraStats: Decodable, Sendable {
        let cameraFps: Double
        let detectionFps: Double
        let processFps: Double
        let skippedFps: Double

        enum CodingKeys: String, CodingKey {
            case cameraFps = "camera_fps"
            case detectionFps = "detection_fps"
            case processFps = "process_fps"
            case skippedFps = "skipped_fps"
        }
    }

    struct DetectorStats: Decodable, Sendable {
        let inferenceSpeed: Double

        enum CodingKeys: String, CodingKey {
            case inferenceSpeed = "inference_speed"
        }
    }

    struct Service: Decodable, Sendable {
        let uptime: Int
        let version: String
    }
}
