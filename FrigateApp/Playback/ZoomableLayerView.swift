import UIKit

/// Shows a video layer at its aspect ratio, centred, with Photos-style zoom.
///
/// Unzoomed, the video is aspect-fit inside the view. Pinching grows it past
/// that box until it fills the whole view and beyond (up to 6×); dragging pans
/// within the picture, and a double tap zooms in on that spot or back out.
/// Zooming scales the layer's host view, so it costs no decoding.
final class ZoomableLayerView: UIView, UIScrollViewDelegate {
    /// Width / height of the video; `nil` fills the view (e.g. a tile already sized to the video).
    var contentAspectRatio: CGFloat? {
        didSet {
            guard contentAspectRatio != oldValue else { return }
            resetLayout()
        }
    }

    var isZoomEnabled = false {
        didSet {
            guard isZoomEnabled != oldValue else { return }
            // Disabled, the scroll view must not swallow pans meant for an
            // enclosing scroll view (the dashboard grid).
            scrollView.pinchGestureRecognizer?.isEnabled = isZoomEnabled
            scrollView.panGestureRecognizer.isEnabled = isZoomEnabled
            doubleTap.isEnabled = isZoomEnabled
            if !isZoomEnabled { scrollView.setZoomScale(1, animated: false) }
        }
    }

    private let scrollView = UIScrollView()
    private let content = LayerHostView()
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        addSubview(scrollView)
        scrollView.addSubview(content)

        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
        doubleTap.isEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func host(_ layer: CALayer) { content.host(layer) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        resetLayout() // new size (e.g. rotation): start again unzoomed
    }

    private func resetLayout() {
        laidOutSize = bounds.size
        scrollView.zoomScale = 1
        scrollView.frame = bounds
        let fitted = fittedSize()
        content.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        centerContent()
    }

    /// The video's aspect-fit size within the view.
    private func fittedSize() -> CGSize {
        guard let ratio = contentAspectRatio, ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds.size }
        if bounds.width / bounds.height > ratio {
            return CGSize(width: (bounds.height * ratio).rounded(), height: bounds.height)
        }
        return CGSize(width: bounds.width, height: (bounds.width / ratio).rounded())
    }

    /// Keeps the picture centred while it's smaller than the view in either direction.
    private func centerContent() {
        let size = scrollView.contentSize
        let horizontal = max(0, (bounds.width - size.width) / 2)
        let vertical = max(0, (bounds.height - size.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            // Zoom so the picture fills the view (at least 2.5×), centred on the tap.
            let fitted = content.bounds.size
            let fill = max(bounds.width / max(fitted.width, 1), bounds.height / max(fitted.height, 1))
            let scale = min(scrollView.maximumZoomScale, max(2.5, fill))
            let point = gesture.location(in: content)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }

    /// Owns the video layer's frame; the layer itself belongs to the player.
    final class LayerHostView: UIView {
        private var hosted: CALayer?

        func host(_ layer: CALayer) {
            // A layer has one superlayer: if another view took it (e.g. the
            // camera opened again from PiP), take it back on the next update.
            guard layer.superlayer !== self.layer else { return }
            if hosted !== layer { hosted?.removeFromSuperlayer() }
            self.layer.addSublayer(layer)
            hosted = layer
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true) // no implicit animation on rotation
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
