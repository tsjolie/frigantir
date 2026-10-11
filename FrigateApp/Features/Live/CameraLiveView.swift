import SwiftUI

/// Full live view of one camera: low-latency video and audio, mute, Picture in
/// Picture, stream selection and a stats overlay.
struct CameraLiveView: View {
    @Environment(AppModel.self) private var model
    let camera: CameraConfig

    @State private var player: LivePlayer?
    @State private var showStats = false

    var body: some View {
        VStack(spacing: 0) {
            // The video view takes all the space above the controls: unzoomed the
            // picture is aspect-fit in the middle, and zooming grows it to fill it.
            ZStack {
                Color.black
                if let player {
                    LiveVideoView(player: player, isZoomable: true, aspectRatio: videoAspectRatio(player))
                    statusOverlay(player)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let player { controls(player) }
        }
        .background(Color.black)
        .navigationTitle(camera.name.cameraDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .onAppear { startPlayer(stream: model.preferredStream(for: camera)) }
        .onDisappear {
            if let player { model.playback.release(player) }
        }
    }

    /// The stream's real shape once known, else the camera's detect resolution.
    private func videoAspectRatio(_ player: LivePlayer) -> CGFloat {
        if let size = player.metrics.videoSize, size.height > 0 { return size.width / size.height }
        return camera.aspectRatio
    }

    private func startPlayer(stream: String) {
        guard let client = model.client else { return }
        player = model.playback.player(camera: camera.name, stream: stream, client: client)
    }

    @ViewBuilder
    private func statusOverlay(_ player: LivePlayer) -> some View {
        VStack {
            if player.state != .playing {
                Label(player.state.label, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: .capsule)
            } else if player.isAudioSuspended {
                Label("Audio paused while another app plays", systemImage: "speaker.slash")
                    .font(.caption.bold())
                    .padding(8)
                    .background(.ultraThinMaterial, in: .capsule)
            }
            Spacer()
            if showStats {
                Text(Self.statsLine(player.metrics))
                    .font(.caption2.monospaced())
                    .padding(6)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
        }
        .padding(8)
    }

    static func statsLine(_ m: LiveStreamEngine.Metrics) -> String {
        let size = m.videoSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "audio only"
        return "\(size) · \(Int(m.kilobitsPerSecond)) kb/s · " + String(format: "%.2f s behind live", m.latency)
    }

    private func controls(_ player: LivePlayer) -> some View {
        HStack(spacing: 32) {
            Button { player.isPaused ? player.play() : player.pause() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
            }
            Button { player.isMuted.toggle() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            NavigationLink {
                CameraHistoryView(camera: camera)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .accessibilityLabel("History")
            }
            Button { showStats.toggle() } label: {
                Image(systemName: "info.circle")
            }
        }
        .font(.title2)
        .foregroundStyle(.white)
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if let player {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    player.isPictureInPictureActive ? player.pictureInPicture.stop() : player.pictureInPicture.start()
                } label: {
                    Label("Picture in Picture", systemImage: player.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                }
                .disabled(!player.isPictureInPictureActive && !player.isPictureInPicturePossible)
            }
        }
        if camera.liveStreams.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(camera.liveStreams, id: \.self) { stream in
                        Button(stream) {
                            model.setPreferredStream(stream, for: camera)
                            startPlayer(stream: stream)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }
}
