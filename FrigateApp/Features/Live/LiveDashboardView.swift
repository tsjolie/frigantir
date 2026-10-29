import SwiftUI

/// The PWA's Live dashboard: camera groups and a grid of camera tiles.
///
/// Pinch the grid to resize the tiles, like the Photos grid: apart for bigger
/// tiles (fewer per row), together for smaller ones. The size is remembered.
struct LiveDashboardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("dashboardGroup") private var group = ""
    /// The narrowest a tile may be; as many columns as fit at this width are shown.
    @AppStorage("dashboardTileWidth") private var tileWidth = 320.0
    /// The pinch in progress, applied on top of `tileWidth` until it ends.
    @GestureState private var pinch: CGFloat = 1
    @State private var gridWidth: CGFloat = 0

    private static let spacing: CGFloat = 8
    private static let smallestTile: CGFloat = 150

    /// Width available to the tiles, inside the grid's padding.
    private var availableWidth: CGFloat { max(0, gridWidth - 2 * Self.spacing) }

    private func columnCount(forTileWidth width: CGFloat) -> Int {
        guard availableWidth > 0 else { return 1 }
        let clamped = min(max(width, Self.smallestTile), availableWidth)
        return max(1, Int((availableWidth + Self.spacing) / (clamped + Self.spacing)))
    }

    private var columnCount: Int { columnCount(forTileWidth: tileWidth * pinch) }

    /// The tile width that shows `count` columns, for stepping one at a time.
    private func tileWidth(forColumns count: Int) -> Double {
        let count = CGFloat(max(1, count))
        return Double((availableWidth - (count - 1) * Self.spacing) / count)
    }

    private var maxColumns: Int { columnCount(forTileWidth: Self.smallestTile) }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error = model.loadError, model.config == nil {
                    ContentUnavailableView("Can't reach Frigate", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing),
                                             count: columnCount),
                              spacing: Self.spacing) {
                        ForEach(model.cameras(in: group.isEmpty ? nil : group)) { camera in
                            NavigationLink(value: camera) {
                                CameraTile(camera: camera)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Self.spacing)
                    .animation(.snappy, value: columnCount)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            // Simultaneous, so scrolling and tapping tiles keep working.
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { value, pinch, _ in pinch = value.magnification }
                    .onEnded { value in
                        // Store the width of the column count the pinch landed on, so
                        // the next pinch starts from what's on screen.
                        let count = columnCount(forTileWidth: tileWidth * value.magnification)
                        tileWidth = tileWidth(forColumns: count)
                    }
            )
            .accessibilityZoomAction { action in
                let count = columnCount
                switch action.direction {
                case .zoomIn: tileWidth = tileWidth(forColumns: count - 1)
                case .zoomOut: tileWidth = tileWidth(forColumns: min(maxColumns, count + 1))
                @unknown default: break
                }
            }
            .navigationTitle(group.isEmpty ? "Live" : group.cameraDisplayName)
            .navigationDestination(for: CameraConfig.self) { CameraLiveView(camera: $0) }
            .toolbar { groupMenu }
            .refreshable { await model.reload() }
            .nowPlayingBar()
        }
    }

    private var groupMenu: some View {
        Menu {
            Picker("Camera group", selection: $group) {
                Label("All cameras", systemImage: "square.grid.2x2").tag("")
                ForEach(model.config?.sortedGroupNames ?? [], id: \.self) { name in
                    Text(name.cameraDisplayName).tag(name)
                }
            }
        } label: {
            Image(systemName: "rectangle.3.group")
        }
    }
}

/// A dashboard tile, behaving like the Frigate web UI's: a still refreshed every
/// 5 s while the camera is quiet, and silent live video while it has motion or
/// a moving object. Live video only runs while the tile is on screen and the
/// app is in the foreground.
struct CameraTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("livePreviews") private var livePreviews = true
    let camera: CameraConfig

    @State private var isVisible = false

    private var isActive: Bool { model.activity.isActive(camera.name) }
    private var showsLive: Bool { livePreviews && isActive && isVisible && scenePhase == .active }

    var body: some View {
        ZStack {
            SnapshotView(url: { date in
                model.client?.latestFrameURL(camera: camera.name, cacheBust: date)
            }, isPaused: showsLive)
            if showsLive, let client = model.client {
                LivePreview(camera: camera.name, stream: model.preferredStream(for: camera), client: client)
            }
        }
        .aspectRatio(camera.aspectRatio, contentMode: .fit)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if isActive {
                    Circle().fill(.red).frame(width: 7, height: 7)
                        .accessibilityLabel("Activity")
                }
                if model.playback.active?.camera == camera.name {
                    Image(systemName: "waveform")
                }
                Text(camera.name.cameraDisplayName)
            }
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(8)
        }
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// Silent live video for a tile. The player exists only while this view is on
/// screen: removing the view (activity ended, tile scrolled away, app in the
/// background) closes the stream.
private struct LivePreview: View {
    let camera: String
    let stream: String
    let client: FrigateClient

    @State private var player: LivePlayer?

    var body: some View {
        ZStack {
            if let player {
                LiveVideoView(player: player, background: .clear)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            let player = LivePlayer(camera: camera, stream: stream,
                                    request: client.liveStreamRequest(stream: stream), isPreview: true,
                                    reauthorize: { [client] in try? await client.login() })
            player.play()
            self.player = player
        }
        .onDisappear {
            player?.close()
            player = nil
        }
    }
}
