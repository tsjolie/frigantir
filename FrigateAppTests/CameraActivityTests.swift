import Foundation
import Testing
@testable import FrigateApp

@Suite struct CameraActivityTests {
    static func message(_ topic: String, _ payload: String) -> FrigateEventStream.Message {
        FrigateEventStream.Message(topic: topic, payload: payload)
    }

    /// Trimmed from a real Frigate 0.18 `camera_activity` message.
    @Test func readsTheSnapshotSentOnConnect() {
        var activity = CameraActivity()
        activity.apply(Self.message("camera_activity", """
        {"ari": {"motion": false, "objects": [], "config": {"detect": false}},
         "gabe": {"motion": true, "objects": []},
         "driveway": {"motion": false, "objects": [{"id": "a", "label": "car", "stationary": true}]},
         "front": {"motion": false, "objects": [{"id": "b", "label": "person", "stationary": false}]}}
        """))
        #expect(!activity.isActive("ari"))
        #expect(activity.isActive("gabe"))
        #expect(!activity.isActive("driveway")) // parked car
        #expect(activity.isActive("front"))
    }

    @Test func followsMotionMessages() {
        var activity = CameraActivity()
        activity.apply(Self.message("ari/motion", "ON"))
        #expect(activity.isActive("ari"))
        activity.apply(Self.message("ari/motion", "OFF"))
        #expect(!activity.isActive("ari"))
        activity.apply(Self.message("ari/audio/dBFS", "-40"))
        #expect(activity.motion.isEmpty)
    }

    @Test func tracksMovingObjectsUntilTheyStopOrEnd() {
        var activity = CameraActivity()
        func event(_ type: String, stationary: Bool) -> FrigateEventStream.Message {
            Self.message("events", """
            {"type": "\(type)", "before": {}, "after": {"id": "x1", "camera": "back",
             "label": "person", "stationary": \(stationary), "false_positive": false}}
            """)
        }
        activity.apply(event("new", stationary: false))
        #expect(activity.isActive("back"))
        activity.apply(event("update", stationary: true))
        #expect(!activity.isActive("back"))
        activity.apply(event("update", stationary: false))
        #expect(activity.isActive("back"))
        activity.apply(event("end", stationary: false))
        #expect(!activity.isActive("back"))
    }
}
