import SwiftUI
import UIKit

/// A camera still that refreshes periodically, keeping the previous frame on
/// screen while the next one loads (AsyncImage would flash a placeholder).
///
/// Dashboard tiles use this instead of live video: a 360p WebP every few seconds
/// costs a few KB, versus megabits per second for a live stream. Refreshing stops
/// automatically when the tile scrolls off screen, because `.task` is cancelled.
struct SnapshotView: View {
    /// The frame URL for a cache-busting timestamp; `nil` while there's no server.
    let url: (Date) -> URL?
    var refreshInterval: Duration = .seconds(5)
    /// Stops refreshing, e.g. while live video covers the still.
    var isPaused = false

    @State private var image: UIImage?

    /// Every still has a unique URL, so caching them only fills the disk.
    /// The default configuration keeps the shared cookie store (Frigate's login).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        // Restarts when un-paused, so a fresh still loads straight away.
        .task(id: isPaused) {
            while !isPaused, !Task.isCancelled {
                if let url = url(.now), let (data, _) = try? await Self.session.data(from: url),
                   let decoded = UIImage(data: data) {
                    image = decoded
                }
                try? await Task.sleep(for: refreshInterval)
            }
        }
    }
}
