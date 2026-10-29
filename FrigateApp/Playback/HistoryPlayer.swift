import AVFoundation
import Observation
import UIKit

/// Plays one camera's recordings at any wall-clock time, for the History screen.
///
/// Footage is loaded an hour at a time as a `/vod` HLS playlist (hardware
/// decoded by AVPlayer). A `RecordingTimeline` per hour translates between the
/// timeline's wall-clock times and playlist positions, and playback rolls over
/// into the next hour when one ends.
@Observable
final class HistoryPlayer {
    let player = AVPlayer()

    /// The wall-clock time of the frame on screen.
    private(set) var currentDate: Date
    private(set) var isPlaying = false
    /// No footage at or after the requested time in its hour.
    private(set) var isMissingFootage = false
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }

    @ObservationIgnored private let client: FrigateClient
    @ObservationIgnored private let camera: String
    @ObservationIgnored private var timeline: RecordingTimeline?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private var isScrubbing = false
    /// Between swapping playlists and landing on the target time, the player
    /// reports position 0; ignore it so the timeline doesn't jump.
    @ObservationIgnored private var isLoading = false

    init(client: FrigateClient, camera: String, start: Date) {
        self.client = client
        self.camera = camera
        currentDate = start
        player.preventsDisplaySleepDuringVideoPlayback = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.playNextHour()
            }
        }
        // Recordings don't play in the background (only live cameras do); the
        // app's audio session would otherwise keep this one going.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    /// Releases the player; call when the History screen goes away.
    func close() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        timeObserver = nil
        endObserver = nil
        backgroundObserver = nil
    }

    func play() {
        isPlaying = true
        player.rate = rate
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentDate.addingTimeInterval(seconds))
    }

    /// Jumps to a wall-clock time, loading that hour's footage if needed.
    func seek(to date: Date) {
        let date = min(date, .now.addingTimeInterval(-2))
        currentDate = date
        if let timeline, timeline.covers(date), let offset = timeline.offset(for: date) {
            isMissingFootage = false
            loadTask?.cancel()
            isLoading = false
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            if isPlaying { player.rate = rate }
        } else {
            load(hourContaining: date, seekTo: date)
        }
    }

    // MARK: - Scrubbing

    func beginScrubbing() {
        isScrubbing = true
        player.pause()
    }

    /// While the timeline is dragged: show nearby frames from the loaded hour,
    /// without loading new playlists on every movement.
    func scrub(to date: Date) {
        currentDate = date
        guard let timeline, timeline.covers(date), let offset = timeline.offset(for: date) else { return }
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func endScrubbing(at date: Date) {
        isScrubbing = false
        seek(to: date)
    }

    // MARK: - Loading

    private func load(hourContaining date: Date, seekTo target: Date) {
        let calendar = Calendar.current
        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let hourEnd = min(hourStart.addingTimeInterval(3600), .now)
        loadTask?.cancel()
        isLoading = true
        loadTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            let segments = (try? await client.recordings(camera: camera, after: hourStart, before: hourEnd)) ?? []
            guard !Task.isCancelled else { return }
            let timeline = RecordingTimeline(start: hourStart, end: hourEnd, segments: segments)
            self.timeline = timeline
            guard let offset = timeline.offset(for: target) else {
                isMissingFootage = true
                player.replaceCurrentItem(with: nil)
                return
            }
            isMissingFootage = false
            let url = client.recordingPlaylistURL(camera: camera, start: hourStart, end: hourEnd)
            player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset.frigate(url)))
            await player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            if isPlaying { player.rate = rate }
        }
    }

    private func playNextHour() {
        guard let timeline else { return }
        // Caught up with the newest footage: stop rather than reload in a loop.
        guard Date.now.timeIntervalSince(timeline.end) > 15 else {
            pause()
            return
        }
        load(hourContaining: timeline.end, seekTo: timeline.end)
    }

    private func playerTimeChanged(_ time: CMTime) {
        guard !isScrubbing, !isLoading, player.currentItem != nil, let timeline,
              let date = timeline.date(atOffset: time.seconds) else { return }
        currentDate = date
    }
}
