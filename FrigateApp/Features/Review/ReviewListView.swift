import SwiftUI

/// The PWA's Review page: unreviewed alerts and detections, newest first.
/// Swipe to mark reviewed; tap to watch the recording. A third tab lists the
/// server's exports.
struct ReviewListView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = Tab.alerts
    @State private var items: [ReviewItem] = []
    @State private var canLoadMore = true
    @State private var error: String?
    /// Only the newest reload may update the list; older ones finish too late.
    @State private var loadGeneration = 0
    @State private var isConfirmingMarkAll = false
    @State private var isMarkingAll = false
    @State private var markAllError: String?

    enum Tab: Hashable {
        case alerts, detections, exports
    }

    /// Which reviews the list shows (the Exports tab has its own list).
    private var severity: ReviewItem.Severity { tab == .detections ? .detection : .alert }

    /// Hides items just marked reviewed, even before the server confirms.
    private var visibleItems: [ReviewItem] {
        items.filter { !model.locallyReviewed.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if tab == .exports {
                    ExportsList()
                } else {
                    reviewList
                }
            }
            .navigationTitle("Review")
            .navigationDestination(for: ReviewItem.self) { ReviewDetailView(item: $0) }
            .navigationDestination(for: FrigateExport.self) { ExportDetailView(export: $0) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $tab) {
                        Text("Alerts").tag(Tab.alerts)
                        Text("Detections").tag(Tab.detections)
                        Text("Exports").tag(Tab.exports)
                    }
                    .pickerStyle(.segmented)
                }
                if tab != .exports {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isMarkingAll {
                            ProgressView()
                        } else {
                            Button("Mark all reviewed", systemImage: "checkmark.circle") { isConfirmingMarkAll = true }
                                .disabled(visibleItems.isEmpty)
                        }
                    }
                }
            }
            .nowPlayingBar()
        }
    }

    private var reviewList: some View {
        List {
            ForEach(visibleItems) { item in
                NavigationLink(value: item) { ReviewRow(item: item) }
                    .swipeActions {
                        Button("Reviewed", systemImage: "checkmark") { markReviewed([item]) }
                            .tint(.green)
                    }
                    .onAppear { if item == visibleItems.last { Task { await loadMore() } } }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visibleItems.isEmpty {
                if let error {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                           description: Text("No unreviewed \(severity.rawValue)s."))
                }
            }
        }
        .confirmationDialog("Mark every unreviewed \(severity.rawValue) as reviewed?",
                            isPresented: $isConfirmingMarkAll, titleVisibility: .visible) {
            Button("Mark All Reviewed") { Task { await markAllReviewed() } }
        }
        .alert("Couldn't mark all reviewed", isPresented: Binding(get: { markAllError != nil },
                                                                 set: { if !$0 { markAllError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(markAllError ?? "")
        }
        .refreshable { await reload() }
        .task(id: severity) { await reload() }
        // Frigate pushed a review change. It sends one every few seconds while
        // an event is in progress, so wait for a quiet second; a newer change
        // cancels the pending reload (and its request).
        .task(id: model.reviewsRevision) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    private func reload() async {
        guard let client = model.client else { return }
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let fetched = try await client.reviews(severity: severity)
            guard generation == loadGeneration else { return }
            // Replacing the list with identical contents would cancel a swipe in progress.
            if fetched != items { items = fetched }
            canLoadMore = !fetched.isEmpty
            error = nil
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard canLoadMore, let client = model.client, let last = items.last else { return }
        // A failed request leaves paging on: the next time the last row
        // appears, it tries again.
        guard let page = try? await client.reviews(severity: severity, before: last.startDate) else { return }
        canLoadMore = !page.isEmpty
        items += page.filter { new in !items.contains { $0.id == new.id } }
    }

    private func markReviewed(_ reviewed: [ReviewItem]) {
        model.markReviewed(reviewed)
    }

    /// Everything of this severity on the server, not just the loaded pages.
    private func markAllReviewed() async {
        isMarkingAll = true
        let severity = severity
        markAllError = await model.markAllReviewed(severity: severity)
        isMarkingAll = false
        if severity == self.severity { await reload() }
    }
}

struct ReviewRow: View {
    @Environment(AppModel.self) private var model
    let item: ReviewItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.client?.reviewThumbnailURL(item)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 112, height: 63)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.camera.cameraDisplayName).font(.headline)
                Text(item.labels.map(\.capitalized).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(item.startDate, format: .dateTime.hour().minute().second())
                    if item.isInProgress {
                        Text("In progress").foregroundStyle(.red)
                    }
                }
                .font(.caption)
            }
        }
    }
}

struct ReviewDetailView: View {
    @Environment(AppModel.self) private var model
    let item: ReviewItem

    var body: some View {
        List {
            if let client = model.client {
                RecordingPlayerView(url: client.reviewPlaylistURL(item))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
            }
            LabeledContent("Camera", value: item.camera.cameraDisplayName)
            LabeledContent("Started", value: item.startDate.formatted(date: .abbreviated, time: .standard))
            LabeledContent("Objects", value: item.labels.joined(separator: ", "))
            if !item.data.zones.isEmpty {
                LabeledContent("Zones", value: item.data.zones.joined(separator: ", "))
            }
        }
        .navigationTitle(item.severity == .alert ? "Alert" : "Detection")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.markReviewed([item])
        }
    }
}
