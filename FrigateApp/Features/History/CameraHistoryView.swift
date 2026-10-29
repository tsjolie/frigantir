import AVFoundation
import SwiftUI

/// Recorded footage for one camera, opened from its live view: the video on
/// top and a scrubbable activity timeline below (beside it in landscape).
struct CameraHistoryView: View {
    @Environment(AppModel.self) private var model
    let camera: CameraConfig

    @State private var player: HistoryPlayer?
    @State private var range: ClosedRange<Date> = Self.initialRange()
    @State private var motion: [MotionActivity] = []
    @State private var reviews: [ReviewItem] = []
    /// Start of the span whose motion is already loaded.
    @State private var loadedFrom: Date?
    @State private var wasPlayingBeforeScrub = false
    /// Picking an export span on the timeline.
    @State private var exportPick: ExportPick?
    /// The span the export sheet opens with.
    @State private var exportRequest: ExportRequest?

    enum ExportPick: Equatable {
        case start
        /// The start is marked; the span runs to wherever the timeline is now.
        case end(from: Date)
    }

    struct ExportRequest: Identifiable {
        let id = UUID()
        let range: ClosedRange<Date>
    }

    /// Recordings are kept for as long as Frigate's retention allows; the
    /// timeline starts with the last day and grows a day at a time.
    private static let maxDays = 30

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    video
                    if let player {
                        controls(player)
                        if let exportPick { exportPickBar(exportPick, player: player) }
                    }
                }
                .frame(maxWidth: landscape ? geometry.size.width * 0.62 : .infinity)
                if let player { timeline(player) }
            }
        }
        .navigationTitle("\(camera.name.cameraDisplayName) History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select on Timeline", systemImage: "hand.draw") { exportPick = .start }
                    Button("Enter Start and End", systemImage: "calendar.badge.clock") {
                        // Defaults to the five minutes before the playback position.
                        let end = min(player?.currentDate ?? .now, .now)
                        exportRequest = ExportRequest(range: end.addingTimeInterval(-300) ... end)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(player == nil || exportPick != nil)
            }
        }
        .sheet(item: $exportRequest) { request in
            ExportSheet(camera: camera, range: request.range)
        }
        .onAppear(perform: start)
        .onDisappear {
            player?.close()
            player = nil
        }
        .task(id: range) { await loadActivity() }
        // Frigate pushed a review change: refresh the bands.
        .onChange(of: model.reviewsRevision) { Task { await loadReviews() } }
    }

    private var video: some View {
        ZStack {
            Color.black
            if let player {
                PlayerLayerView(player: player.player, aspectRatio: camera.aspectRatio)
                if player.isMissingFootage {
                    Label("No recording at this time", systemImage: "video.slash")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial, in: .capsule)
                }
            }
        }
        .aspectRatio(camera.aspectRatio, contentMode: .fit)
    }

    private func controls(_ player: HistoryPlayer) -> some View {
        HStack(spacing: 28) {
            Button { player.skip(by: -10) } label: { Image(systemName: "gobackward.10") }
            Button { player.isPlaying ? player.pause() : player.play() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { player.skip(by: 10) } label: { Image(systemName: "goforward.10") }
            Menu {
                Picker("Speed", selection: Bindable(player).rate) {
                    ForEach([1, 2, 4, 8] as [Float], id: \.self) { Text("\(Int($0))×").tag($0) }
                }
            } label: {
                Text("\(Int(player.rate))×").font(.body.monospacedDigit().bold())
            }
        }
        .font(.title2)
        .padding(.vertical, 10)
    }

    /// Steps for picking an export span: scroll the timeline to each end and mark it.
    private func exportPickBar(_ pick: ExportPick, player: HistoryPlayer) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                switch pick {
                case .start:
                    Text("Export: scroll to the start").font(.subheadline.bold())
                    Text("Move the timeline so the line is at the first moment to export.")
                case .end(let from):
                    Text("Export: scroll to the end").font(.subheadline.bold())
                    Text("From \(from.formatted(date: .omitted, time: .standard)) to the line.")
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { exportPick = nil }
            switch pick {
            case .start:
                Button("Set Start") {
                    player.pause()
                    exportPick = .end(from: player.currentDate)
                }
                .buttonStyle(.borderedProminent)
            case .end(let from):
                Button("Set End") {
                    let to = player.currentDate
                    exportRequest = ExportRequest(range: min(from, to) ... max(from, to))
                    exportPick = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// The export span picked so far, from the marked start to the line.
    private func exportSelection(_ player: HistoryPlayer) -> ClosedRange<Date>? {
        guard case .end(let from) = exportPick else { return nil }
        return min(from, player.currentDate) ... max(from, player.currentDate)
    }

    private func timeline(_ player: HistoryPlayer) -> some View {
        ActivityTimeline(
            range: range,
            motion: motion,
            reviews: reviews,
            currentDate: player.currentDate,
            canLoadEarlier: range.upperBound.timeIntervalSince(range.lowerBound) < Double(Self.maxDays) * 86400,
            selection: exportSelection(player),
            onScrubBegan: {
                wasPlayingBeforeScrub = player.isPlaying
                player.beginScrubbing()
            },
            onScrub: { player.scrub(to: $0) },
            onScrubEnded: { date in
                player.endScrubbing(at: date)
                if wasPlayingBeforeScrub { player.play() }
            },
            onTap: { date in
                // Tapping a review band starts just before the activity.
                if let item = reviews.first(where: { $0.startTime <= date.timeIntervalSince1970
                    && ($0.endTime ?? .infinity) >= date.timeIntervalSince1970 }) {
                    player.seek(to: item.startDate.addingTimeInterval(-3))
                } else {
                    player.seek(to: date)
                }
                player.play()
            },
            onLoadEarlier: {
                range = range.lowerBound.addingTimeInterval(-86400) ... range.upperBound
            })
    }

    // MARK: - Data

    /// The last 24 hours, ending at the top of the next hour.
    private static func initialRange() -> ClosedRange<Date> {
        let end = Calendar.current.dateInterval(of: .hour, for: .now)?.end ?? .now
        return end.addingTimeInterval(-86400) ... end
    }

    private func start() {
        guard player == nil, let client = model.client else { return }
        // Pause this camera's live audio so it doesn't play over the recording.
        if let live = model.playback.active, live.camera == camera.name, !live.isPaused {
            live.pause()
        }
        let player = HistoryPlayer(client: client, camera: camera.name, start: .now.addingTimeInterval(-60))
        player.seek(to: player.currentDate)
        self.player = player
    }

    /// Loads motion for the part of the range not loaded yet ("Load earlier"
    /// adds a day below), and reviews for the whole range.
    private func loadActivity() async {
        guard let client = model.client else { return }
        let from = range.lowerBound
        let to = loadedFrom ?? range.upperBound
        guard from < to else { return }
        async let newMotion = client.motionActivity(camera: camera.name, after: from, before: to)
        await loadReviews()
        if let newMotion = try? await newMotion {
            motion += newMotion
            loadedFrom = from
        }
    }

    private func loadReviews() async {
        guard let client = model.client else { return }
        if let items = try? await client.reviews(camera: camera.name, after: range.lowerBound, before: range.upperBound) {
            reviews = items
        }
    }
}

/// Video surface for an AVPlayer, without the system controls (the timeline
/// replaces the scrubber, which would only know about one hour). Pinch to zoom,
/// drag to pan, double tap to zoom in or out, like the live view.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var aspectRatio: CGFloat?

    func makeCoordinator() -> AVPlayerLayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        return layer
    }

    func makeUIView(context: Context) -> ZoomableLayerView {
        let view = ZoomableLayerView()
        view.isZoomEnabled = true
        view.host(context.coordinator)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ZoomableLayerView, context: Context) {
        if context.coordinator.player !== player { context.coordinator.player = player }
        view.contentAspectRatio = aspectRatio
    }
}
