import Foundation
import Testing
@testable import FrigateApp

@Suite struct RecordingTimelineTests {
    static func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    /// 1000–1020 recorded, gap until 1050, 1050–1060 recorded.
    let timeline = RecordingTimeline(start: date(1000), end: date(1100), segments: [
        RecordingSegment(startTime: 1050, endTime: 1060),
        RecordingSegment(startTime: 1000, endTime: 1010),
        RecordingSegment(startTime: 1010, endTime: 1020),
    ])

    @Test func skipsGapsWhenMappingToThePlaylist() throws {
        #expect(timeline.duration == 30)
        #expect(timeline.offset(for: Self.date(1005)) == 5)
        #expect(timeline.offset(for: Self.date(1055)) == 25) // 20 s before the gap + 5 s
        #expect(timeline.offset(for: Self.date(1030)) == 20) // in the gap: next recorded moment
        #expect(timeline.offset(for: Self.date(1070)) == nil) // nothing recorded afterwards
    }

    @Test func mapsPlaylistPositionsBackToWallClock() {
        #expect(timeline.date(atOffset: 5) == Self.date(1005))
        #expect(timeline.date(atOffset: 25) == Self.date(1055))
        #expect(timeline.date(atOffset: 99) == Self.date(1060)) // clamps to the end of footage
    }

    @Test func trimsSegmentsToTheRequestedRange() {
        let trimmed = RecordingTimeline(start: Self.date(1005), end: Self.date(1015), segments: [
            RecordingSegment(startTime: 1000, endTime: 1010),
            RecordingSegment(startTime: 1010, endTime: 1020),
        ])
        #expect(trimmed.duration == 10)
        #expect(trimmed.offset(for: Self.date(1005)) == 0)
        #expect(trimmed.offset(for: Self.date(1012)) == 7)
    }

    @Test func ignoresOverlappingSegments() {
        let overlapping = RecordingTimeline(start: Self.date(0), end: Self.date(100), segments: [
            RecordingSegment(startTime: 0, endTime: 10),
            RecordingSegment(startTime: 5, endTime: 15),
        ])
        #expect(overlapping.duration == 15)
        #expect(overlapping.offset(for: Self.date(12)) == 12)
    }

    @Test func decodesTimelineResponses() throws {
        let motion = try JSONDecoder().decode([MotionActivity].self, from: Data("""
        [{"start_time":1791293670,"motion":15.96,"camera":"driveway"}]
        """.utf8))
        #expect(motion.first?.startTime == 1791293670)
        let segments = try JSONDecoder().decode([RecordingSegment].self, from: Data("""
        [{"id":"1791293688.0-p2ptin","start_time":1791293688,"end_time":1791293697.887022,
          "segment_size":6.06,"motion":215,"objects":0,"duration":9.89}]
        """.utf8))
        #expect(segments.first?.endTime == 1791293697.887022)
    }
}
