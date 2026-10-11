import AVFoundation
import Observation

/// UI-facing wrapper around one `LiveStreamEngine`: observable state for SwiftUI,
/// mute, Picture in Picture and background/foreground behaviour.
@Observable
final class LivePlayer: Identifiable {
    let camera: String
    let stream: String
    let displayLayer = AVSampleBufferDisplayLayer()
    let pictureInPicture = PictureInPictureController()

    private(set) var state: LiveStreamEngine.State = .idle
    private(set) var metrics = LiveStreamEngine.Metrics()
    private(set) var isPictureInPictureActive = false
    private(set) var isPictureInPicturePossible = false
    private(set) var isPaused = false
    /// Another app's audio has priority; video keeps playing silently.
    private(set) var isAudioSuspended = false
    var isMuted = false {
        didSet { engine.setMuted(isMuted) }
    }

    var id: String { stream }

    /// Fired when PiP starts/stops, so PlaybackManager can keep the player alive.
    var onPictureInPictureChanged: ((Bool) -> Void)?

    @ObservationIgnored private let engine: LiveStreamEngine
    @ObservationIgnored private let request: URLRequest

    /// `isPreview`: a silent dashboard tile, with no audio and no Picture in Picture.
    init(camera: String, stream: String, request: URLRequest, isPreview: Bool = false) {
        self.camera = camera
        self.stream = stream
        self.request = request
        displayLayer.videoGravity = .resizeAspect
        engine = LiveStreamEngine(displayLayer: displayLayer, includesAudio: !isPreview)

        engine.onStateChange = { [weak self] state in self?.state = state }
        engine.onMetrics = { [weak self] metrics in self?.metrics = metrics }

        // Only one player may offer PiP; previews would compete for swipe-home auto-PiP.
        if !isPreview { pictureInPicture.attach(to: displayLayer) }
        pictureInPicture.onActiveChanged = { [weak self] active in
            guard let self else { return }
            isPictureInPictureActive = active
            // Video must be decoding while PiP is on screen, even in the background.
            if active { engine.setVideoEnabled(true); engine.setMode(.videoAndAudio) }
            onPictureInPictureChanged?(active)
        }
        pictureInPicture.onPossibleChanged = { [weak self] possible in
            self?.isPictureInPicturePossible = possible
        }
        pictureInPicture.onSetPlaying = { [weak self] playing in
            if playing { self?.play() } else { self?.pause() }
        }
    }

    func play() {
        isPaused = false
        pictureInPicture.isPaused = false
        engine.start(request)
        pictureInPicture.invalidatePlaybackState()
    }

    /// Live streams can't meaningfully pause, so pausing disconnects; playing
    /// again reconnects at the live edge.
    func pause() {
        isPaused = true
        pictureInPicture.isPaused = true
        engine.stop()
        pictureInPicture.invalidatePlaybackState()
    }

    func resyncToLive() { engine.resync() }

    /// Gives up audio to another app while video keeps playing (e.g. in PiP).
    func suspendAudio() {
        isAudioSuspended = true
        engine.setAudioEnabled(false)
    }

    /// Takes audio back at the live edge.
    func resumeAudio() {
        isAudioSuspended = false
        engine.setAudioEnabled(true)
    }

    /// App went to the background without PiP: stop feeding the video decoder
    /// (iOS forbids GPU/decoder work in the background anyway) and, if asked,
    /// switch to an audio-only stream so video isn't downloaded either.
    func enterBackground() {
        guard !isPictureInPictureActive else { return }
        engine.setVideoEnabled(false)
    }

    func switchToAudioOnly() {
        guard !isPictureInPictureActive, !isAudioSuspended else { return }
        engine.setMode(.audioOnly)
    }

    func enterForeground() {
        engine.setMode(.videoAndAudio)
        engine.setVideoEnabled(true)
    }

    /// Releases the network session. The player can't be reused afterwards.
    func close() {
        pictureInPicture.stop()
        engine.shutdown()
    }
}
