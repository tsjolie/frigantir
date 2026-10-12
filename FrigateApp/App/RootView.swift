import SwiftUI

/// Tab layout mirroring the Frigate PWA: Live, Review, Explore, Settings. History
/// opens from a camera's live view.
struct RootView: View {
    @Environment(AppModel.self) private var model

    /// What's shown full screen over the tabs. There's one slot, so a new
    /// request replaces whatever is showing (SwiftUI dismisses it and presents
    /// the new one), instead of being lost behind it.
    enum Presentation: Identifiable, Hashable {
        /// A camera reopened from Picture in Picture or the now-playing bar.
        case camera(String)
        /// A review from a tapped notification.
        case review(String)

        var id: Self { self }
    }

    /// A notification's review takes precedence over a camera; closing the
    /// review goes back to the camera.
    private var presentation: Presentation? {
        if let id = model.presentedReviewID { return .review(id) }
        if let camera = model.playback.cameraToPresent { return .camera(camera) }
        return nil
    }

    var body: some View {
        if model.isConfigured {
            TabView {
                Tab("Live", systemImage: "video") {
                    LiveDashboardView()
                }
                Tab("Review", systemImage: "exclamationmark.bubble") {
                    ReviewListView()
                }
                .badge(model.reviewSummary?.last24Hours.unreviewedAlerts ?? 0)
                Tab("Explore", systemImage: "magnifyingglass") {
                    ExploreView()
                }
                Tab("Settings", systemImage: "gear") {
                    NavigationStack { SettingsView() }
                }
            }
            // Full-screen covers can't be swiped away; each closes through its
            // Done button, which clears the state above. So the binding only reads.
            .fullScreenCover(item: Binding(get: { presentation }, set: { _ in })) { presentation in
                switch presentation {
                case .camera(let name):
                    cameraCover(name)
                case .review(let id):
                    NotificationReviewView(reviewID: id)
                }
            }
        } else {
            NavigationStack { SettingsView(isOnboarding: true) }
        }
    }

    @ViewBuilder
    private func cameraCover(_ name: String) -> some View {
        NavigationStack {
            if let camera = model.config?.cameras[name] {
                CameraLiveView(camera: camera)
                    .toolbar {
                        Button("Done") { model.playback.cameraToPresent = nil }
                    }
            } else {
                ContentUnavailableView("Camera unavailable", systemImage: "video.slash")
                    .toolbar {
                        Button("Done") { model.playback.cameraToPresent = nil }
                    }
            }
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
