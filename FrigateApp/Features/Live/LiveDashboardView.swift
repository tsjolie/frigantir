import SwiftUI

/// The PWA's Live dashboard: camera groups and a grid of camera tiles.
struct LiveDashboardView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("dashboardGroup") private var group = ""

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error = model.loadError, model.config == nil {
                    ContentUnavailableView("Can't reach Frigate", systemImage: "wifi.exclamationmark",
                                           description: Text(error))
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.cameras(in: group.isEmpty ? nil : group)) { camera in
                            NavigationLink(value: camera) {
                                CameraTile(camera: camera)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
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
