import AVFoundation
import MediaPlayer
import os

/// Owns the app's audio session and lock-screen presence.
///
/// Background audio on iOS needs three things, all set up here or in project.yml:
///  1. `UIBackgroundModes: audio` in Info.plist,
///  2. an active `.playback` audio session (not `.ambient`/`.soloAmbient`),
///  3. audio actually playing. While it plays, iOS keeps the process running,
///     so the stream's WebSocket stays connected with the screen locked.
///
/// The same session setup is what Picture in Picture requires.
final class AudioSessionController {
    /// Another app (a call, Siri, a video in Instagram…) took the audio.
    var onInterruptionBegan: (() -> Void)?
    /// The other app is done with audio: the system said we may resume, or the
    /// watch started by `watchForOtherAudioToStop` saw its audio stop.
    var onOtherAudioFinished: (() -> Void)?
    /// Audio services restarted (rare); the session was set up again.
    var onMediaServicesReset: (() -> Void)?
    var onRemotePlay: (() -> Void)?
    var onRemotePause: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var otherAudioWatch: Task<Void, Never>?

    /// `setCategory` and `setActive` block while the system reconfigures audio
    /// hardware, which can take long enough to stall the UI, so they run on a
    /// serial queue. Serial keeps activate/deactivate calls in the order made.
    private nonisolated static let sessionQueue = DispatchQueue(label: "AudioSessionController", qos: .userInitiated)
    private nonisolated static let log = Logger(subsystem: "net.sjolie.frigateapp", category: "audio")

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    Self.log.info("Audio interrupted by another app; yielding")
                    self?.onInterruptionBegan?()
                case .ended where options.contains(.shouldResume):
                    // The other app deactivated and invited others to resume.
                    Self.log.info("Interruption ended with shouldResume; taking audio back")
                    self?.onOtherAudioFinished?()
                default:
                    // Ended without `shouldResume` (e.g. the user started music):
                    // the other app still has priority; the watch decides.
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configure()
                self?.activate()
                self?.onMediaServicesReset?()
            }
        })
        configure()
        setUpRemoteCommands()
    }

    func configure() {
        Self.sessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            } catch {
                Self.log.error("Audio session category error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Polls for the other app's audio to stop, for apps that end their audio
    /// without notifying others (many social and video apps), so no "ended"
    /// interruption ever arrives. Fires `onOtherAudioFinished` once no other
    /// app has played non-mixable audio for `quietPeriod`.
    func watchForOtherAudioToStop(quietPeriod: Duration = .seconds(3)) {
        otherAudioWatch?.cancel()
        otherAudioWatch = Task { [weak self] in
            var quietSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                // Either hint means another app is still playing; requiring both
                // to clear avoids taking the audio back while it's in use.
                let session = AVAudioSession.sharedInstance()
                if session.secondaryAudioShouldBeSilencedHint || session.isOtherAudioPlaying {
                    quietSince = nil
                } else if let since = quietSince {
                    if ContinuousClock.now - since >= quietPeriod {
                        Self.log.info("Other app's audio stopped; taking audio back")
                        self?.otherAudioWatch = nil
                        self?.onOtherAudioFinished?()
                        return
                    }
                } else {
                    quietSince = .now
                }
            }
        }
    }

    func stopWatchingOtherAudio() {
        otherAudioWatch?.cancel()
        otherAudioWatch = nil
    }

    func activate() {
        Self.sessionQueue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Self.log.error("Audio session activation error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func deactivate() {
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Lock screen / Control Center entry for the live camera.
    func updateNowPlaying(title: String, isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Frigantir",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    private func setUpRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            self?.onRemotePlay?()
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            self?.onRemotePause?()
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
    }
}
