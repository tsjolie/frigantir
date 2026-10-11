import Foundation

/// Which cameras have activity right now, decided the way Frigate's web UI
/// decides when a dashboard tile switches from a still image to live video:
/// motion, or a tracked object that's moving (a parked car doesn't count).
///
/// Built from Frigate's WebSocket: a `camera_activity` snapshot on connect, then
/// `<camera>/motion` ON/OFF and `events` new/update/end messages. Frigate already
/// holds motion ON for a while after it stops (`mqtt_off_delay`, 30 s by
/// default), so tiles don't flap between still and live.
struct CameraActivity: Equatable {
    private(set) var motion: Set<String> = []
    /// IDs of moving tracked objects, per camera.
    private(set) var objects: [String: Set<String>] = [:]

    func isActive(_ camera: String) -> Bool {
        motion.contains(camera) || objects[camera]?.isEmpty == false
    }

    mutating func apply(_ message: FrigateEventStream.Message) {
        if message.topic == "camera_activity" {
            applySnapshot(message.payload)
        } else if message.topic == "events" {
            applyEvent(message.payload)
        } else if message.topic.hasSuffix("/motion") {
            let camera = String(message.topic.dropLast("/motion".count))
            guard !camera.contains("/") else { return }
            if message.payload == "ON" { motion.insert(camera) } else { motion.remove(camera) }
        }
    }

    /// `{"front": {"motion": true, "objects": [{"id": …, "stationary": false}, …]}, …}`
    private mutating func applySnapshot(_ payload: String) {
        guard let cameras = Self.json(payload) else { return }
        motion = []
        objects = [:]
        for (camera, value) in cameras {
            guard let state = value as? [String: Any] else { continue }
            if state["motion"] as? Bool == true { motion.insert(camera) }
            let moving = (state["objects"] as? [[String: Any]] ?? [])
                .filter { $0["stationary"] as? Bool != true }
                .enumerated()
                .map { index, object in object["id"] as? String ?? "\(camera)-\(index)" }
            if !moving.isEmpty { objects[camera] = Set(moving) }
        }
    }

    /// `{"type": "new"|"update"|"end", "after": {"id": …, "camera": …, "stationary": …}}`
    private mutating func applyEvent(_ payload: String) {
        guard let event = Self.json(payload), let type = event["type"] as? String,
              let after = event["after"] as? [String: Any],
              let id = after["id"] as? String, let camera = after["camera"] as? String else { return }
        let isMoving = type != "end"
            && after["stationary"] as? Bool != true
            && after["false_positive"] as? Bool != true
        if isMoving {
            objects[camera, default: []].insert(id)
        } else {
            objects[camera]?.remove(id)
            if objects[camera]?.isEmpty == true { objects[camera] = nil }
        }
    }

    private static func json(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}
