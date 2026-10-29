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

    /// App Review typed the address without a scheme; that has to work.
    @Test(arguments: [
        ("frigate.example.com", "https://frigate.example.com"),
        ("  frigate.example.com/  ", "https://frigate.example.com"),
        ("192.168.1.10:8971", "https://192.168.1.10:8971"),
        ("nas.local:8971/frigate/", "https://nas.local:8971/frigate"),
        ("http://192.168.1.10:5000", "http://192.168.1.10:5000"),
        ("HTTPS://frigate.example.com", "https://frigate.example.com"),
    ])
    func parsesServerAddress(typed: String, expected: String) {
        #expect(URL.serverAddress(typed)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://frigate.example.com", "https://", "not a host"])
    func rejectsInvalidServerAddress(typed: String) {
        #expect(URL.serverAddress(typed) == nil)
    }

    /// The notification server's registration contract (notifier/README.md).
    @Test func encodesNotifierRegistration() throws {
        let registration = NotifierClient.Registration(
            token: "abcd", environment: "production", bundleID: "net.sjolie.frigateapp", deviceName: "iPhone",
            severities: ["alert"], cameras: ["front"], ignoreVerified: true)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any])
        #expect(json["ignore_verified"] as? Bool == true)
        #expect(json["bundle_id"] as? String == "net.sjolie.frigateapp")
        #expect(json["device_name"] as? String == "iPhone")
        #expect(json["cameras"] as? [String] == ["front"])
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
        var counts = summary.last24Hours
        counts.markAllReviewed(.detection)
        #expect(counts.unreviewedDetections == 0)
        #expect(counts.unreviewedAlerts == 75)
        counts.markAllReviewed(.alert)
        #expect(counts.unreviewedAlerts == 0)

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

    @Test func decodesExportsAndBuildsTheirURLs() throws {
        let json = """
        [{"id":"driveway_ab12cd","camera":"driveway","name":"Package: 10/29","date":1790128888.5,
          "video_path":"/media/frigate/exports/driveway_ab12cd.mp4",
          "thumb_path":"/media/frigate/clips/export/driveway_ab12cd.webp","in_progress":false},
         {"id":"garage_ef34","camera":"garage","name":null,"date":1790128999.0,
          "video_path":"/media/frigate/exports/garage_ef34.mp4","thumb_path":null,"in_progress":true}]
        """
        let exports = try JSONDecoder().decode([FrigateExport].self, from: Data(json.utf8))
        let first = try #require(exports.first)
        #expect(client.exportVideoURL(first).absoluteString == "https://frigate.example.com/exports/driveway_ab12cd.mp4")
        #expect(client.exportThumbnailURL(first)?.path == "/clips/export/driveway_ab12cd.webp")
        #expect(first.fileName == "Package- 10-29.mp4")
        #expect(exports[1].inProgress)
        #expect(exports[1].displayName == "Garage")
        #expect(client.exportThumbnailURL(exports[1]) == nil)
    }

    /// 12 AM is midnight and 12 PM is noon on the export time wheels.
    @Test func convertsBetweenTwelveAndTwentyFourHourTime() {
        #expect(TwelveHourClock(hour: 0) == TwelveHourClock(hourRow: 0, isPM: false))
        #expect(TwelveHourClock(hour: 12) == TwelveHourClock(hourRow: 0, isPM: true))
        #expect(TwelveHourClock(hour: 23) == TwelveHourClock(hourRow: 11, isPM: true))
        #expect(TwelveHourClock.displayHour(row: 0) == 12)
        #expect(TwelveHourClock.displayHour(row: 7) == 7)
        for hour in 0 ..< 24 {
            #expect(TwelveHourClock(hour: hour).hour == hour)
        }
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
