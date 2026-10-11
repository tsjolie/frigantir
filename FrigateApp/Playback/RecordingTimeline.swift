import Foundation

/// Maps wall-clock time onto a Frigate `/vod` HLS playlist and back.
///
/// The playlist for a time range concatenates only the recording segments that
/// exist (trimmed to the range), so every gap in the recordings shifts all later
/// moments earlier in the player. Seeking by "seconds since range start" would
/// land on the wrong footage whenever recording paused, e.g. motion-only retention.
nonisolated struct RecordingTimeline: Sendable, Equatable {
    /// A stretch of contiguous footage: wall-clock seconds and where it starts in the playlist.
    struct Span: Sendable, Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let offset: TimeInterval
    }

    let start: Date
    let end: Date
    let spans: [Span]

    init(start: Date, end: Date, segments: [RecordingSegment]) {
        self.start = start
        self.end = end
        let lower = start.timeIntervalSince1970
        let upper = end.timeIntervalSince1970
        var spans: [Span] = []
        var offset: TimeInterval = 0
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let from = max(segment.startTime, lower, spans.last?.end ?? lower)
            let to = min(segment.endTime, upper)
            guard to > from else { continue }
            spans.append(Span(start: from, end: to, offset: offset))
            offset += to - from
        }
        self.spans = spans
    }

    var isEmpty: Bool { spans.isEmpty }

    /// Total playlist length.
    var duration: TimeInterval {
        spans.last.map { $0.offset + $0.end - $0.start } ?? 0
    }

    func covers(_ date: Date) -> Bool {
        start <= date && date < end
    }

    /// Playlist position for a wall-clock time. A time inside a gap maps to the
    /// next recorded moment; `nil` if nothing is recorded at or after it.
    func offset(for date: Date) -> TimeInterval? {
        let t = date.timeIntervalSince1970
        guard let span = spans.first(where: { t < $0.end }) else { return nil }
        return span.offset + max(0, t - span.start)
    }

    /// Wall-clock time shown at a playlist position.
    func date(atOffset offset: TimeInterval) -> Date? {
        guard let span = spans.last(where: { $0.offset <= offset }) ?? spans.first else { return nil }
        let t = min(span.start + max(0, offset - span.offset), span.end)
        return Date(timeIntervalSince1970: t)
    }
}
