import AVKit
import SwiftUI

/// Plays recorded footage (Frigate's HLS `/vod` playlists or export MP4s) with
/// the system player, which brings hardware decoding, scrubbing and AirPlay.
///
/// Picture in Picture is only for live cameras, so recordings don't offer it,
/// and they pause when the app goes to the background.
struct RecordingPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        context.coordinator.controller = controller
        controller.player = makePlayer()
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if (controller.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            controller.player = makePlayer()
            controller.player?.play()
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
    }

    final class Coordinator {
        weak var controller: AVPlayerViewController?
        // Set once in init; deinit only removes it.
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init() {
            // The app keeps an audio session for live cameras, which would
            // otherwise let a recording carry on playing in the background.
            observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.player?.pause() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private func makePlayer() -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset.frigate(url)))
    }
}

extension AVURLAsset {
    /// AVPlayer doesn't read the shared cookie store on its own; pass the
    /// Frigate auth cookie explicitly so /vod works with auth enabled.
    static func frigate(_ url: URL) -> AVURLAsset {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
    }
}
