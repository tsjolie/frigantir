import SwiftUI

/// Tab layout mirroring the Frigate PWA: Live, Review, Explore, Settings. History
/// opens from a camera's live view.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = AppTab.live

    enum AppTab: Hashable { case live, review, explore, settings }

    var body: some View {
        let playback = model.playback
        let presentingCamera = Binding(
            get: { playback.cameraToPresent != nil },
            set: { if !$0 { playback.cameraToPresent = nil } })

        if model.isConfigured {
            TabView(selection: $selectedTab) {
                Tab("Live", systemImage: "video", value: .live) {
                    LiveDashboardView()
                }
                Tab("Review", systemImage: "exclamationmark.bubble", value: .review) {
                    ReviewListView()
                }
                .badge(model.reviewSummary?.last24Hours.unreviewedAlerts ?? 0)
                Tab("Explore", systemImage: "magnifyingglass", value: .explore) {
                    ExploreView()
                }
                Tab("Settings", systemImage: "gear", value: .settings) {
                    NavigationStack { SettingsView() }
                }
            }
            // A tapped notification: the Review tab opens the review.
            .onChange(of: model.reviewToOpen, initial: true) {
                if model.reviewToOpen != nil { selectedTab = .review }
            }
            // Returning from Picture in Picture opens the camera it was showing.
            .fullScreenCover(isPresented: presentingCamera) {
                if let name = playback.cameraToPresent, let camera = model.config?.cameras[name] {
                    NavigationStack {
                        CameraLiveView(camera: camera)
                            .toolbar {
                                Button("Done") { playback.cameraToPresent = nil }
                            }
                    }
                }
            }
        } else {
            NavigationStack { SettingsView(isOnboarding: true) }
        }
    }
}

/// Mini player shown above content while a camera keeps playing off-screen
/// (baby-monitor mode). Tap to return to the camera; ✕ to stop.
struct NowPlayingBar: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if let player = model.playback.active, model.playback.visibleStream != player.stream {
                HStack(spacing: 12) {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: !player.isMuted && !player.isPaused)
                    Button {
                        model.playback.cameraToPresent = player.camera
                    } label: {
                        VStack(alignment: .leading) {
                            Text(player.camera.cameraDisplayName).font(.subheadline.bold())
                            Text(player.state.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button { player.isMuted.toggle() } label: {
                        Image(systemName: player.isMuted ? "speaker.slash" : "speaker.wave.2")
                    }
                    Button { model.playback.stop() } label: {
                        Image(systemName: "xmark")
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
    }
}

extension View {
    func nowPlayingBar() -> some View { modifier(NowPlayingBar()) }
}

extension LiveStreamEngine.State {
    var label: String {
        switch self {
        case .idle: "Stopped"
        case .connecting: "Connecting…"
        case .playing: "Live"
        case .reconnecting(let attempt, _): "Reconnecting (\(attempt))…"
        case .failed(let reason): reason
        }
    }
}
