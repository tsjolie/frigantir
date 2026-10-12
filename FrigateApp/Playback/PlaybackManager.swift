import Observation
import SwiftUI

/// App-wide owner of live players.
///
/// Players outlive the screen that created them when they are in Picture in
/// Picture or when "keep audio when leaving camera" is on, which is what makes
/// the app usable as a baby monitor: open a camera, go back to the dashboard or
/// lock the phone, and the audio keeps going. Only one player is "active"
/// (audible, on the lock screen) at a time.
///
/// Other apps' audio takes priority: when one starts (a video in Instagram, a
/// call), the camera gives up its audio but keeps its video (in PiP or on
/// screen), and takes the audio back once the other app is finished.
@Observable
final class PlaybackManager {
    private(set) var active: LivePlayer?
    /// The stream whose camera screen is on screen right now, if any.
    private(set) var visibleStream: String?
    /// Set when the user taps "restore" in the PiP window.
    var cameraToPresent: String?

    @ObservationIgnored var settings = ServerSettings.load()
    @ObservationIgnored private let audio = AudioSessionController()
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var isInBackground = false
    /// Set when a muted player was paused on entering the background.
    @ObservationIgnored private var pausedWhileMuted = false

    /// How the active player yielded to another app's audio.
    private enum Interruption {
        /// Video still playing (PiP or on screen), audio dropped.
        case audioSuspended
        /// In the background without PiP there's nothing to show: disconnected.
        case paused
    }
    @ObservationIgnored private var interruption: Interruption?

    init() {
        audio.onInterruptionBegan = { [weak self] in self?.yieldToOtherAudio() }
        audio.onOtherAudioFinished = { [weak self] in self?.resumeAfterOtherAudio() }
        audio.onMediaServicesReset = { [weak self] in self?.active?.resyncToLive() }
        audio.onRemotePlay = { [weak self] in
            guard let self else { return }
            // Pressing play on the lock screen means "let me hear it", even
            // over another app.
            active?.isMuted = false
            if interruption != nil {
                resumeAfterOtherAudio()
            } else {
                active?.play()
                refreshNowPlaying()
            }
        }
        audio.onRemotePause = { [weak self] in self?.active?.pause(); self?.refreshNowPlaying() }
    }

    /// Returns the running player for this stream, or starts a new one and makes it active.
    func player(camera: String, stream: String, client: FrigateClient) -> LivePlayer {
        visibleStream = stream
        if let active, active.stream == stream {
            if active.isPaused { active.play() }
            return active
        }
        active?.close()

        let player = LivePlayer(camera: camera, stream: stream, request: client.liveStreamRequest(stream: stream),
                                reauthorize: { try? await client.login() })
        player.onPictureInPictureChanged = { [weak self, weak player] isActive in
            guard let self, let player else { return }
            // PiP closed while the camera screen is gone: nothing is showing it anymore.
            if !isActive, visibleStream != player.stream, !settings.keepAudioWhenLeavingCamera, active === player {
                stop()
            } else if !isActive, active === player {
                if isInBackground, interruption == .audioSuspended {
                    // No audio and no longer any video on screen: disconnect until
                    // the other app is done.
                    player.pause()
                    interruption = .paused
                } else {
                    pauseIfSilentInBackground()
                }
            }
        }
        player.pictureInPicture.onRestoreUserInterface = { [weak self, weak player] in
            // If the camera screen is still open underneath, PiP just returns to it;
            // presenting a second copy would take the video layer away from it.
            guard let self, let player, visibleStream != player.stream else { return }
            cameraToPresent = camera
        }
        active = player
        audio.activate()
        player.play()
        refreshNowPlaying()
        return player
    }

    /// Called when a camera screen disappears.
    func release(_ player: LivePlayer) {
        if visibleStream == player.stream { visibleStream = nil }
        guard active === player else { return }
        if player.isPictureInPictureActive || settings.keepAudioWhenLeavingCamera { return }
        stop()
    }

    func stop() {
        active?.close()
        active = nil
        interruption = nil
        audio.stopWatchingOtherAudio()
        audio.deactivate()
    }

    // MARK: - Other apps' audio

    /// Another app took the audio session. Give it the audio for as long as it
    /// plays instead of fighting over the session.
    private func yieldToOtherAudio() {
        guard let active, !active.isPaused, interruption == nil else { return }
        if active.isPictureInPictureActive || !isInBackground {
            active.suspendAudio()
            interruption = .audioSuspended
        } else {
            backgroundTask?.cancel()
            backgroundTask = nil
            active.pause()
            interruption = .paused
        }
        audio.watchForOtherAudioToStop()
    }

    /// The other app is finished: take the audio back, at the live edge.
    private func resumeAfterOtherAudio() {
        audio.stopWatchingOtherAudio()
        guard let kind = interruption else { return }
        interruption = nil
        guard let active else { return }
        audio.activate()
        switch kind {
        case .audioSuspended:
            active.resumeAudio()
        case .paused:
            active.play()
            if isInBackground { scheduleAudioOnly(active) }
        }
        refreshNowPlaying()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard let active else { return }
        switch phase {
        case .background:
            isInBackground = true
            if pauseIfSilentInBackground() { return }
            active.enterBackground()
            scheduleAudioOnly(active)
        case .active:
            isInBackground = false
            backgroundTask?.cancel()
            backgroundTask = nil
            if pausedWhileMuted {
                pausedWhileMuted = false
                audio.activate()
                active.play()
                refreshNowPlaying()
            }
            if interruption == .paused {
                // Back on screen while the other app still has the audio: show
                // the video, keep yielding the audio.
                active.suspendAudio()
                active.play()
                interruption = .audioSuspended
            }
            active.enterForeground()
        default:
            break
        }
    }

    /// iOS only lets an app run in the background while it plays audible
    /// content (App Review guideline 2.5.4). A muted camera without Picture in
    /// Picture would keep streaming silently, so disconnect it and let the app
    /// suspend; it reconnects when the app returns to the foreground.
    @discardableResult
    private func pauseIfSilentInBackground() -> Bool {
        guard isInBackground, let active, active.isMuted, !active.isPictureInPictureActive, !active.isPaused
        else { return false }
        backgroundTask?.cancel()
        backgroundTask = nil
        active.pause()
        pausedWhileMuted = true
        audio.deactivate() // also clears the lock-screen entry
        return true
    }

    /// Without PiP, the background stream drops to audio-only after a delay.
    private func scheduleAudioOnly(_ player: LivePlayer) {
        backgroundTask?.cancel()
        guard let delay = settings.audioOnlyAfterBackgroundSeconds else { return }
        backgroundTask = Task { [weak player] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            player?.switchToAudioOnly()
        }
    }

    private func refreshNowPlaying() {
        guard let active else { return }
        audio.updateNowPlaying(title: active.camera.cameraDisplayName, isPlaying: !active.isPaused)
    }
}

extension String {
    /// "front_door" → "Front Door", the way Frigate's UI labels cameras.
    var cameraDisplayName: String {
        replacingOccurrences(of: "_", with: " ").capitalized
    }
}
