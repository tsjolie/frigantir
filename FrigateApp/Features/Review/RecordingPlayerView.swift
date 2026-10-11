import AVKit
import SwiftUI

/// Plays recorded footage (Frigate's HLS `/vod` playlists or `clip.mp4`) with
/// the system player, which brings hardware decoding, scrubbing, AirPlay,
/// background audio and Picture in Picture for free.
struct RecordingPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
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

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
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
