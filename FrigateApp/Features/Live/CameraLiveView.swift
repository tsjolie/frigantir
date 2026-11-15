import SwiftUI

/// Full live view of one camera: low-latency video and audio, mute, Picture in
/// Picture, stream selection and a stats overlay.
struct CameraLiveView: View {
    @Environment(AppModel.self) private var model
    let camera: CameraConfig

    @State private var player: LivePlayer?
    @State private var showStats = false
    @State private var showVolume = false
    @State private var volumeHideTask: Task<Void, Never>?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

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
            volumeHideTask?.cancel()
            showVolume = false
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
            Button {
                player.isMuted.toggle()
                showVolumeBriefly()
            } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
            }
            .overlay(alignment: .bottom) {
                if showVolume {
                    volumeSlider(player)
                        .offset(y: -44)
                        .transition(.opacity)
                }
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

    /// Shown above the speaker button when it's tapped, and hidden after
    /// 1.5 s untouched. Not a popover: that would swallow the next tap on the
    /// button.
    private func volumeSlider(_ player: LivePlayer) -> some View {
        VolumeSlider(player: player, camera: camera.name) { editing in
            if editing { volumeHideTask?.cancel() } else { showVolumeBriefly() }
        }
        .frame(width: 180)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: .capsule)
        .environment(\.colorScheme, .dark)
        .disabled(player.isAudioSuspended)
    }

    /// Shows the volume slider, or keeps it up, for another 1.5 s. VoiceOver
    /// users get as long as they need; it hides when they leave the screen.
    private func showVolumeBriefly() {
        withAnimation(.easeOut(duration: 0.15)) { showVolume = true }
        volumeHideTask?.cancel()
        guard !voiceOverEnabled else { return }
        volumeHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { showVolume = false }
        }
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

/// A camera's volume: 0 when muted, else its last level. Dragging to zero
/// mutes but keeps the level from before the drag, so unmuting brings it
/// back; the level is remembered per camera.
///
/// Not a `Slider`: that moves relative to where the thumb was, and the camera
/// screen re-rendering every second (stream stats) mid-drag threw it off, so
/// reaching 0 or 100 took a big overshoot. Here the level is wherever the
/// finger is on the bar, and past either end is exactly 0 or 100.
struct VolumeSlider: View {
    let player: LivePlayer
    let camera: String
    /// True while dragging.
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var value: Double = 0
    @State private var isDragging = false
    /// The level when the drag began. Dragging to 0 passes through tiny levels
    /// on the way; unmuting should bring back this one, not those.
    @State private var levelBeforeDrag: Float = 1

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Group {
                    Capsule().fill(.primary.opacity(0.25))
                    Capsule().fill(.primary).frame(width: width * value)
                }
                .frame(height: 8)
                // Centred on the level; it overhangs the ends into the padding.
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .scaleEffect(isDragging ? 1.15 : 1)
                    .animation(.easeOut(duration: 0.1), value: isDragging)
                    .offset(x: width * value - 10)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            levelBeforeDrag = player.volume
                            onEditingChanged(true)
                        }
                        setValue(drag.location.x / max(width, 1))
                    }
                    .onEnded { _ in
                        isDragging = false
                        if value == 0 { player.volume = levelBeforeDrag }
                        CameraVolumes.setVolume(player.volume, for: camera)
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            setValue(value + (direction == .increment ? 0.1 : -0.1))
            CameraVolumes.setVolume(player.volume, for: camera)
            onEditingChanged(false)
        }
        .onAppear { value = playerValue }
        // The speaker button tapped while the bar is up.
        .onChange(of: player.isMuted) {
            if !isDragging { value = playerValue }
        }
    }

    private var playerValue: Double { player.isMuted ? 0 : Double(player.volume) }

    private func setValue(_ newValue: Double) {
        value = min(max(newValue, 0), 1)
        if value > 0 { player.volume = Float(value) }
        if player.isMuted != (value == 0) { player.isMuted = value == 0 }
    }
}
