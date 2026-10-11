import Foundation
import Testing
@testable import FrigateApp

/// Decoding tests use trimmed copies of real Frigate 0.18 responses.
@Suite struct FrigateAPITests {
    let client = FrigateClient(baseURL: URL(string: "https://frigate.example.com")!)

    @Test func decodesReviewItem() throws {
        let json = """
        [{"id":"1790128892.170424-ctcks0","camera":"driveway","start_time":1790128892.170424,
          "end_time":null,"severity":"detection",
          "thumb_path":"/media/frigate/clips/review/thumb-driveway-1790128892.170424-ctcks0.webp",
          "data":{"detections":["1790128891.998477-37srb0"],"objects":["person"],"verified_objects":[],
                  "sub_labels":[],"zones":[],"audio":["speech"],"thumb_time":1790128892.446644,"metadata":null},
          "has_been_reviewed":false}]
        """
        let items = try JSONDecoder().decode([ReviewItem].self, from: Data(json.utf8))
        let item = try #require(items.first)
        #expect(item.severity == .detection)
        #expect(item.isInProgress)
        #expect(item.labels == ["person", "speech"])
        #expect(client.reviewThumbnailURL(item).absoluteString
            == "https://frigate.example.com/clips/review/thumb-driveway-1790128892.170424-ctcks0.webp")
    }

    /// `/api/review/<id>` (used to open a notification's review) has no `has_been_reviewed`.
    @Test func decodesSingleReviewWithoutReviewState() throws {
        let json = """
        {"id":"1790128892.170424-ctcks0","camera":"driveway","start_time":1790128892.17,"end_time":1790128900.5,
         "severity":"alert","thumb_path":"/media/frigate/clips/review/thumb.webp",
         "data":{"detections":[],"objects":["person"],"sub_labels":[],"zones":["yard"],"audio":[]}}
        """
        let item = try JSONDecoder().decode(ReviewItem.self, from: Data(json.utf8))
        #expect(!item.hasBeenReviewed)
        #expect(item.severity == .alert)
        #expect(!item.isInProgress)
    }

    @Test func decodesConfigAndKeepsCameraNames() throws {
        let json = """
        {"cameras":{
           "front_door":{"name":"front_door","enabled":true,"live":{"streams":{"Main":"front_door","Sub":"front_door_sub"}},
                         "ui":{"order":2,"dashboard":true},"detect":{"width":1280,"height":720}},
           "garage":{"name":"garage","enabled":true,"ui":{"order":1,"dashboard":true}},
           "hidden":{"name":"hidden","enabled":true,"ui":{"order":0,"dashboard":false}}},
         "camera_groups":{"House":{"cameras":["front_door"],"icon":"LuCctv","order":1}}}
        """
        let config = try JSONDecoder().decode(FrigateConfig.self, from: Data(json.utf8))
        #expect(config.dashboardCameras.map(\.name) == ["garage", "front_door"])
        #expect(config.cameras["front_door"]?.liveStreams == ["front_door", "front_door_sub"])
        #expect(config.cameras["garage"]?.liveStreams == ["garage"])
        #expect(config.sortedGroupNames == ["House"])
        #expect("front_door".cameraDisplayName == "Front Door")
    }

    @Test func decodesSummaryAndStats() throws {
        let summary = try JSONDecoder().decode(ReviewSummary.self, from: Data("""
        {"last24Hours":{"reviewed_alert":4,"reviewed_detection":0,"total_alert":79,"total_detection":59},
         "2026-09-22":{"day":"2026-09-22","reviewed_alert":0,"reviewed_detection":0,"total_alert":78,"total_detection":63}}
        """.utf8))
        #expect(summary.last24Hours.unreviewedAlerts == 75)

        let stats = try JSONDecoder().decode(FrigateStats.self, from: Data("""
        {"cameras":{"front":{"camera_fps":14.9,"detection_fps":2.1,"process_fps":5.0,"skipped_fps":0.0,"pid":1}},
         "detectors":{"coral":{"inference_speed":6.72,"pid":2}},
         "service":{"uptime":86400,"version":"0.18.0-344efb6","storage":{}}}
        """.utf8))
        #expect(stats.detectors["coral"]?.inferenceSpeed == 6.72)
    }

    @Test func buildsMediaURLs() {
        #expect(client.liveStreamRequest(stream: "gabe").url?.absoluteString
            == "wss://frigate.example.com/live/mse/api/ws?src=gabe")
        #expect(client.eventsWebSocketURL().absoluteString == "wss://frigate.example.com/ws")
        let start = Date(timeIntervalSince1970: 1_790_128_888)
        #expect(client.recordingPlaylistURL(camera: "driveway", start: start, end: start.addingTimeInterval(17)).path
            == "/vod/driveway/start/1790128888/end/1790128905/index.m3u8")

        let plain = FrigateClient(baseURL: URL(string: "http://192.168.1.10:5000")!)
        #expect(plain.eventsWebSocketURL().absoluteString == "ws://192.168.1.10:5000/ws")
    }

    @Test func decodesWebSocketMessages() {
        let string = FrigateEventStream.decode(#"{"topic":"reviews","payload":"{\"type\":\"new\"}"}"#)
        #expect(string?.topic == "reviews")
        #expect(string?.payload == #"{"type":"new"}"#)

        let object = FrigateEventStream.decode(#"{"topic":"camera_activity","payload":{"front":{"motion":true}}}"#)
        #expect(object?.payload.contains("motion") == true)
        #expect(FrigateEventStream.decode("not json") == nil)
    }
}
