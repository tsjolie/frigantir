import AVFoundation
import SwiftUI
import UIKit

/// Hosts a player's `AVSampleBufferDisplayLayer` in SwiftUI.
///
/// The layer is owned by the player, not the view, so the picture survives the
/// view being rebuilt and the same layer keeps feeding Picture in Picture.
///
/// With `isZoomable`, the view can be larger than the video: the picture sits
/// aspect-fit in the middle, and zooming grows it to fill the whole view (see
/// `ZoomableLayerView`). Picture in Picture still shows the whole frame.
struct LiveVideoView: UIViewRepresentable {
    let player: LivePlayer
    var isZoomable = false
    /// Width / height of the video, for fitting it inside a larger view.
    var aspectRatio: CGFloat?
    /// Clear lets a dashboard tile's still show through until the first frame.
    var background: UIColor = .black

    func makeUIView(context: Context) -> ZoomableLayerView {
        let view = ZoomableLayerView()
        view.backgroundColor = background
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ZoomableLayerView, context: Context) {
        view.isZoomEnabled = isZoomable
        view.contentAspectRatio = aspectRatio
        view.host(player.displayLayer)
    }
}
