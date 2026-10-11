import AVKit
import os

/// Picture in Picture for a live `AVSampleBufferDisplayLayer`.
///
/// PiP simply re-parents the display layer's output into the system PiP window;
/// the stream engine keeps enqueueing into the same layer, so there is no second
/// decoder and no extra work.
final class PictureInPictureController: NSObject {
    private(set) var controller: AVPictureInPictureController?
    var onActiveChanged: ((Bool) -> Void)?
    var onSetPlaying: ((Bool) -> Void)?
    /// Called when the user taps "restore" in the PiP window; navigate back to the camera.
    var onRestoreUserInterface: (() -> Void)?
    var isPaused = false
    /// PiP can only start once the layer is on screen and showing frames;
    /// until then `start()` does nothing, so the UI disables the button.
    var onPossibleChanged: ((Bool) -> Void)?

    private let log = Logger(subsystem: "net.sjolie.frigateapp", category: "pip")
    private var possibleObservation: NSKeyValueObservation?

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard Self.isSupported, controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        // Swiping home while a live camera is on screen starts PiP automatically.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true // hides the ±15s skip buttons
        controller.delegate = self
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in
                self?.log.debug("PiP possible: \(possible)")
                self?.onPossibleChanged?(possible)
            }
        }
        self.controller = controller
    }

    func start() {
        guard let controller else { return }
        if !controller.isPictureInPicturePossible { log.error("start() while PiP is not possible") }
        controller.startPictureInPicture()
    }
    func stop() { controller?.stopPictureInPicture() }

    /// Tell the PiP window that play/pause state changed from inside the app.
    func invalidatePlaybackState() { controller?.invalidatePlaybackState() }
}

extension PictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        isPaused = !playing
        onSetPlaying?(playing)
    }

    /// An infinite range tells PiP this is live content (no scrubber).
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        isPaused
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime) async {}
}

extension PictureInPictureController: AVPictureInPictureControllerDelegate {
    /// Reported before the app moves to the background on swipe-home, so the
    /// player keeps feeding video instead of pausing the decoder.
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        log.debug("PiP will start")
        onActiveChanged?(true)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        onActiveChanged?(false)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        log.debug("PiP started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        onActiveChanged?(false)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onRestoreUserInterface?()
        completionHandler(true)
    }
}
