import AVFoundation
import Foundation
import Network

/// Plays one go2rtc live stream with the lowest overhead iOS allows:
///
///     go2rtc ──WebSocket(fMP4)──▶ FMP4Demuxer ──CMSampleBuffer──▶ AVSampleBufferVideoRenderer ─┐
///                                                          └────▶ AVSampleBufferAudioRenderer ─┴▶ AVSampleBufferRenderSynchronizer
///
/// The renderers decode on the hardware media engine (VideoToolbox / Audio
/// Toolbox), there is no transcoding anywhere, and the display layer is the same
/// object Picture in Picture uses, so PiP costs nothing extra.
///
/// Networking, demuxing and enqueueing all run on one private serial queue (the
/// URLSession delegate queue targets it), so the main thread never touches media
/// data. Mutable state is confined to that queue, hence `@unchecked Sendable`.
///
/// The engine keeps the stream alive on its own: it reconnects with exponential
/// backoff on errors, restarts when no data arrives for `stallTimeout`, reconnects
/// immediately when the network path comes back, and skips ahead when latency
/// drifts past `maxLatency`.
nonisolated final class LiveStreamEngine: NSObject, @unchecked Sendable {
    enum MediaMode: Sendable, Equatable {
        case videoAndAudio
        /// Asks go2rtc for audio only; used in the background to save bandwidth and battery.
        case audioOnly
    }

    enum State: Sendable, Equatable {
        case idle
        case connecting
        case playing
        case reconnecting(attempt: Int, delay: TimeInterval)
        case failed(String)
    }

    struct Metrics: Sendable, Equatable {
        var kilobitsPerSecond: Double = 0
        var latency: TimeInterval = 0
        var videoSize: CGSize?
        var codecs: String?
    }

    struct Tuning: Sendable {
        /// Delay added when anchoring the clock, to absorb network jitter.
        var jitterBuffer: TimeInterval = 0.3
        /// Latency above which playback skips forward to the live edge.
        var maxLatency: TimeInterval = 1.5
        /// No bytes for this long means the stream is dead; reconnect.
        var stallTimeout: TimeInterval = 6
        var maxBackoff: TimeInterval = 15
    }

    /// Codecs advertised to go2rtc, mirroring its own web client. H.264/HEVC and
    /// AAC are all hardware- or natively-decoded on iOS.
    static let videoCodecs = ["avc1.640029", "avc1.64002A", "avc1.640033", "hvc1.1.6.L153.B0"]
    static let audioCodecs = ["mp4a.40.2", "mp4a.40.5"]

    let displayLayer: AVSampleBufferDisplayLayer
    /// False for silent dashboard previews: go2rtc isn't asked for audio and no
    /// audio renderer runs, so a preview never touches the audio session (and
    /// never interrupts music playing in another app).
    let includesAudio: Bool
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()

    /// Called on the main actor.
    var onStateChange: (@MainActor @Sendable (State) -> Void)?
    var onMetrics: (@MainActor @Sendable (Metrics) -> Void)?

    private let tuning: Tuning
    private let queue = DispatchQueue(label: "LiveStreamEngine", qos: .userInitiated)
    private var urlSession: URLSession!
    private let pathMonitor = NWPathMonitor()

    // Everything below is only touched on `queue`.
    private var request: URLRequest?
    private var mode: MediaMode = .videoAndAudio
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var state: State = .idle
    private var attempt = 0
    private let demuxer = FMP4Demuxer()
    private var watchdog: DispatchSourceTimer?
    private var clockAnchored = false
    private var awaitingKeyframe = true
    private var videoEnabled = true
    /// False while another app has priority over our audio (see `setAudioEnabled`).
    private var audioEnabled = true
    /// Whether `audioRenderer` is currently attached to the synchronizer.
    private var audioAttached = false
    private var audioRemovalPending = false
    private var latestPTS: CMTime = .invalid
    private var lastDataAt = Date.distantPast
    private var bytesSinceTick = 0
    private var metrics = Metrics()
    private var pathSatisfied = true

    /// The display layer's renderer, captured on the main actor so the media
    /// queue never touches the (main-actor) layer itself. Enqueueing and flushing
    /// a renderer from a background queue is the documented usage.
    private let videoRenderer: AVSampleBufferVideoRenderer

    @MainActor
    init(displayLayer: AVSampleBufferDisplayLayer, includesAudio: Bool = true, tuning: Tuning = Tuning()) {
        self.displayLayer = displayLayer
        self.includesAudio = includesAudio
        self.videoRenderer = displayLayer.sampleBufferRenderer
        self.tuning = tuning
        super.init()

        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)

        // iOS 27 deprecates addRenderer/enqueue/flush in favour of
        // `sampleBufferReceiver(adding:)`; the classic API is kept while the
        // deployment target is below 27 (see docs/PROJECT_PLAN.md, Phase 6).
        synchronizer.addRenderer(videoRenderer)
        if includesAudio {
            synchronizer.addRenderer(audioRenderer)
            audioAttached = true
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        pathMonitor.start(queue: queue)
    }

    // MARK: - Public controls (thread-safe)

    func start(_ request: URLRequest, mode: MediaMode = .videoAndAudio) {
        queue.async { [self] in
            self.request = request
            self.mode = mode
            attempt = 0
            connect()
        }
    }

    /// Switches between full and audio-only streams by reconnecting.
    func setMode(_ mode: MediaMode) {
        queue.async { [self] in
            guard mode != self.mode, request != nil else { return }
            self.mode = mode
            connect()
        }
    }

    /// Stops feeding the video decoder (e.g. app backgrounded without PiP) while
    /// audio keeps playing. Re-enabling waits for the next keyframe.
    func setVideoEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard enabled != videoEnabled else { return }
            videoEnabled = enabled
            if enabled {
                videoRenderer.flush()
                awaitingKeyframe = true
            }
        }
    }

    /// Drops the audio while keeping video running, for when another app's audio
    /// takes priority (an audio session interruption).
    ///
    /// Disabled, the stream reconnects asking go2rtc for video only, and the
    /// audio renderer leaves the synchronizer, so the clock runs on host time.
    /// That matters: with the audio renderer attached, restarting the clock
    /// (which the latency check does) restarts audio and takes the session back
    /// from the other app, and the two apps then keep pausing each other.
    /// Enabling reattaches the renderer and reconnects at the live edge.
    func setAudioEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard includesAudio, enabled != audioEnabled else { return }
            audioEnabled = enabled
            teardownConnection() // stops the clock, so renderers can change safely
            updateAudioAttachment()
            if request != nil {
                attempt = 0
                connect()
            }
        }
    }

    /// Brings the synchronizer's renderers in line with `audioEnabled`. Removal
    /// completes asynchronously; a re-enable that arrives meanwhile is applied
    /// when it finishes.
    private func updateAudioAttachment() {
        if audioEnabled, !audioAttached, !audioRemovalPending {
            synchronizer.addRenderer(audioRenderer)
            audioAttached = true
        } else if !audioEnabled, audioAttached {
            audioAttached = false
            audioRemovalPending = true
            synchronizer.removeRenderer(audioRenderer, at: synchronizer.currentTime()) { [weak self] _ in
                guard let self else { return }
                queue.async {
                    self.audioRemovalPending = false
                    self.updateAudioAttachment()
                }
            }
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [self] in audioRenderer.isMuted = muted }
    }

    /// Jump to the live edge, e.g. after an audio interruption ends.
    func resync() {
        queue.async { [self] in
            guard latestPTS.isValid else { return }
            audioRenderer.flush()
            anchorClock(at: latestPTS)
        }
    }

    func stop() {
        queue.async { [self] in
            request = nil
            teardownConnection()
            setState(.idle)
        }
    }

    /// Call when discarding the engine; URLSession retains its delegate until invalidated.
    func shutdown() {
        queue.async { [self] in
            request = nil
            teardownConnection()
            pathMonitor.cancel()
            urlSession.invalidateAndCancel()
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        guard let request else { return }
        teardownConnection()
        generation += 1
        metrics = Metrics()
        setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt, delay: 0))

        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024 // 5 MP keyframes can be large
        self.task = task
        task.resume()

        // go2rtc's MSE handshake: advertise codecs; it replies with the MIME type
        // it chose, then streams the init segment and fragments as binary frames.
        let withAudio = includesAudio && audioEnabled
        // Audio-only mode with audio suspended would ask for nothing: send video.
        let withVideo = mode == .videoAndAudio || !withAudio
        let codecs = (withVideo ? Self.videoCodecs : []) + (withAudio ? Self.audioCodecs : [])
        let hello = #"{"type":"mse","value":"\#(codecs.joined(separator: ","))"}"#
        task.send(.string(hello)) { [weak self] error in
            if let error { self?.connectionFailed(error.localizedDescription, task: task) }
        }
        receive(on: task)
        lastDataAt = Date()
        startWatchdog()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .success(.data(let data)):
                handleMedia(data)
                receive(on: task)
            case .success(.string(let text)):
                handleControl(text, task: task)
                receive(on: task)
            case .success:
                receive(on: task)
            case .failure(let error):
                connectionFailed(error.localizedDescription, task: task)
            }
        }
    }

    private func handleControl(_ text: String, task: URLSessionWebSocketTask) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        let value = json["value"] as? String
        switch type {
        case "mse":
            metrics.codecs = value
        case "error":
            connectionFailed(value ?? "go2rtc error", task: task)
        default:
            break
        }
    }

    private func handleMedia(_ data: Data) {
        lastDataAt = Date()
        bytesSinceTick += data.count
        let outputs: [FMP4Demuxer.Output]
        do {
            outputs = try demuxer.append(data)
        } catch {
            connectionFailed("Stream decode error: \(error)", task: task)
            return
        }

        for output in outputs {
            switch output {
            case .initialized(let video, _):
                if let video {
                    let d = CMVideoFormatDescriptionGetDimensions(video)
                    metrics.videoSize = CGSize(width: Int(d.width), height: Int(d.height))
                }
            case .video(let sample):
                enqueueVideo(sample)
            case .audio(let sample):
                guard includesAudio, audioEnabled, audioAttached else { continue }
                anchorClockIfNeeded(CMSampleBufferGetPresentationTimeStamp(sample))
                audioRenderer.enqueue(sample)
                noteEnqueued(sample)
            }
        }
    }

    private func enqueueVideo(_ sample: CMSampleBuffer) {
        guard videoEnabled else { return }

        // After a flush, or if the system tore down the decoder while we were in
        // the background, decoding can only restart from a keyframe.
        if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding {
            videoRenderer.flush()
            awaitingKeyframe = true
        }
        if awaitingKeyframe {
            guard sample.isKeyframe else { return }
            awaitingKeyframe = false
        }
        anchorClockIfNeeded(CMSampleBufferGetPresentationTimeStamp(sample))
        videoRenderer.enqueue(sample)
        noteEnqueued(sample)
    }

    private func noteEnqueued(_ sample: CMSampleBuffer) {
        let end = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
        if !latestPTS.isValid || end > latestPTS { latestPTS = end }
        if state != .playing {
            attempt = 0
            setState(.playing)
        }
    }

    private func anchorClockIfNeeded(_ pts: CMTime) {
        guard !clockAnchored else { return }
        anchorClock(at: pts)
    }

    private func anchorClock(at pts: CMTime) {
        clockAnchored = true
        synchronizer.setRate(1, time: pts - CMTime(seconds: tuning.jitterBuffer, preferredTimescale: 1000))
    }

    private func connectionFailed(_ reason: String, task failedTask: URLSessionWebSocketTask?) {
        guard failedTask === task, request != nil else { return }
        teardownConnection()
        attempt += 1
        let backoff = min(tuning.maxBackoff, 0.5 * pow(2, Double(attempt - 1)))
        let delay = backoff * Double.random(in: 0.8 ... 1.2)
        setState(.reconnecting(attempt: attempt, delay: delay))

        let scheduled = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == scheduled, request != nil else { return }
            connect()
        }
    }

    private func teardownConnection() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        watchdog?.cancel()
        watchdog = nil
        demuxer.reset()
        synchronizer.setRate(0, time: .zero)
        videoRenderer.flush()
        audioRenderer.flush()
        clockAnchored = false
        awaitingKeyframe = true
        latestPTS = .invalid
    }

    private func pathChanged(_ path: NWPath) {
        let satisfied = path.status == .satisfied
        defer { pathSatisfied = satisfied }
        // Network came back (Wi-Fi ↔ cellular, VPN up): don't wait out the backoff.
        if satisfied, !pathSatisfied, request != nil, state != .playing {
            attempt = max(attempt, 1)
            connect()
        }
    }

    // MARK: - Watchdog: stall detection, latency control, metrics

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        watchdog = timer
    }

    private func tick() {
        if Date().timeIntervalSince(lastDataAt) > tuning.stallTimeout {
            connectionFailed("Stream stalled", task: task)
            return
        }

        if clockAnchored, latestPTS.isValid {
            let lead = (latestPTS - synchronizer.currentTime()).seconds
            // Too far behind live (e.g. after a network burst) or the clock ran
            // past the data (starved): re-anchor near the newest sample.
            if lead > tuning.maxLatency || lead < -0.5 {
                audioRenderer.flush()
                anchorClock(at: latestPTS)
            }
            metrics.latency = max(0, lead)
        }

        metrics.kilobitsPerSecond = Double(bytesSinceTick * 8) / 1000
        bytesSinceTick = 0
        let snapshot = metrics
        if let onMetrics {
            Task { @MainActor in onMetrics(snapshot) }
        }
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        if let onStateChange {
            Task { @MainActor in onStateChange(newState) }
        }
    }
}

extension LiveStreamEngine: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        connectionFailed("Closed by server (\(closeCode.rawValue))", task: webSocketTask)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let webSocketTask = task as? URLSessionWebSocketTask else { return }
        connectionFailed(error.localizedDescription, task: webSocketTask)
    }
}

extension CMSampleBuffer {
    nonisolated var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [NSDictionary],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
