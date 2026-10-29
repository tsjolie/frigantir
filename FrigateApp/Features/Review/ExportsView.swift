import AVFoundation
import Photos
import SwiftUI

/// The Review page's Exports tab: recordings saved on the server (from the
/// History screen or Frigate's web UI), to watch, download and share.
struct ExportsList: View {
    @Environment(AppModel.self) private var model
    @State private var exports: [FrigateExport] = []
    @State private var error: String?
    @State private var hasLoaded = false
    @State private var pendingDelete: FrigateExport?

    var body: some View {
        List {
            ForEach(exports) { export in
                NavigationLink(value: export) { ExportRow(export: export) }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = export }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if exports.isEmpty, hasLoaded {
                if let error {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ContentUnavailableView("No exports", systemImage: "film.stack", description: Text("""
                        Export footage from a camera's History screen. Exports made in Frigate's web UI \
                        show up here too.
                        """))
                }
            }
        }
        .confirmationDialog("Delete \"\(pendingDelete?.displayName ?? "")\" from the server?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { export in
            Button("Delete Export", role: .destructive) { Task { await delete(export) } }
        }
        .refreshable { await load() }
        .task { await load() }
        // While Frigate is still writing an export, check on it every few seconds.
        .task(id: exports.contains(where: \.inProgress)) {
            while exports.contains(where: \.inProgress), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            let fetched = try await client.exports()
            if fetched != exports { exports = fetched }
            error = nil
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }

    private func delete(_ export: FrigateExport) async {
        guard let client = model.client else { return }
        exports.removeAll { $0.id == export.id }
        do {
            try await client.deleteExport(id: export.id)
            ExportDownloader.removeDownload(of: export)
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

private struct ExportRow: View {
    @Environment(AppModel.self) private var model
    let export: FrigateExport

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.client?.exportThumbnailURL(export)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(export.displayName).font(.headline).lineLimit(2)
                Text(export.camera.cameraDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if export.inProgress {
                    Label("Exporting…", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                } else {
                    Text(export.createdDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                }
            }
        }
    }
}

/// One export: plays it, downloads it to Photos, shares it (Save to Files,
/// AirDrop, Messages…), or deletes it from the server.
struct ExportDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let export: FrigateExport

    @State private var downloader = ExportDownloader()
    @State private var isConfirmingDelete = false
    @State private var error: String?
    /// Picked once, so finishing a download doesn't restart the video.
    @State private var playbackURL: URL?
    @State private var isSavingToPhotos = false
    @State private var savedToPhotos = false
    /// Where the saved video landed; Photos files it by the recording date.
    @State private var savedMessage: String?

    /// What to do with the video once the app has it.
    private enum Action { case saveToPhotos, share }

    var body: some View {
        List {
            if export.inProgress {
                ContentUnavailableView("Still exporting", systemImage: "hourglass",
                                       description: Text("Frigate is still saving this export. Check back shortly."))
            } else if let playbackURL {
                RecordingPlayerView(url: playbackURL)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
            }

            Section {
                LabeledContent("Camera", value: export.camera.cameraDisplayName)
                LabeledContent("Created", value: export.createdDate.formatted(date: .abbreviated, time: .standard))
            }

            if !export.inProgress {
                Section {
                    actionButtons
                    if let savedMessage {
                        Text(savedMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                } footer: {
                    Text("""
                        Download saves the video to your photo library. Share sends it with AirDrop, \
                        Messages and more, or saves it to Files.
                        """)
                }
            }

            Section {
                Button("Delete Export", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
            }
        }
        .navigationTitle(export.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this export from the server?", isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Export", role: .destructive) { Task { await delete() } }
        }
        .onAppear {
            downloader.checkForDownload(of: export)
            // A downloaded copy plays without the network.
            playbackURL = playbackURL ?? downloader.downloadedFile ?? model.client?.exportVideoURL(export)
        }
        .onDisappear { downloader.cancel() }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if case .downloading(let fraction) = downloader.state {
            HStack {
                ProgressView(value: fraction) {
                    Text("Downloading… \(fraction, format: .percent.precision(.fractionLength(0)))")
                        .font(.footnote)
                }
                Button("Cancel") { downloader.cancel() }
                    .buttonStyle(.borderless)
            }
        } else {
            Button {
                perform(.saveToPhotos)
            } label: {
                HStack {
                    Label(savedToPhotos ? "Saved to Photos" : "Download",
                          systemImage: savedToPhotos ? "checkmark.circle" : "arrow.down.circle")
                    if isSavingToPhotos {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(savedToPhotos || isSavingToPhotos)
            Button("Share", systemImage: "square.and.arrow.up") { perform(.share) }
        }
    }

    /// Gets the video (reusing an earlier download), then saves or shares it.
    private func perform(_ action: Action) {
        guard let client = model.client else { return }
        error = nil
        exportLog.info("\(String(describing: action), privacy: .public) export \(export.id, privacy: .public)")
        downloader.download(export, client: client) { result in
            switch result {
            case .success(let file):
                switch action {
                case .share:
                    ShareSheet.present([file]) { failure in
                        if let failure { error = failure.localizedDescription }
                    }
                case .saveToPhotos:
                    Task { await saveToPhotos(file) }
                }
            case .failure(let failure):
                exportLog.error("Download failed: \(failure.localizedDescription, privacy: .public)")
                error = failure.localizedDescription
            }
        }
    }

    private func saveToPhotos(_ file: URL) async {
        isSavingToPhotos = true
        defer { isSavingToPhotos = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        exportLog.info("Photos add-only authorization: \(status.rawValue)")
        guard status == .authorized || status == .limited else {
            error = "Frigantir isn't allowed to add to Photos. Turn it on in Settings › Apps › Frigantir › Photos."
            return
        }
        do {
            let id = try await PhotoLibrary.saveVideo(file)
            exportLog.info("Saved to Photos as \(id, privacy: .public)")
            savedToPhotos = true
            savedMessage = await Self.savedMessage(for: file)
        } catch {
            exportLog.error("Saving to Photos failed: \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    /// Photos sorts by when a video was recorded, so a saved export appears
    /// under that day, not today.
    private static func savedMessage(for file: URL) async -> String {
        let recorded = try? await AVURLAsset(url: file).load(.creationDate)?.load(.dateValue)
        guard let recorded else { return "Saved. Find it in Photos under Recently Saved." }
        return """
            Saved. Photos files it under \(recorded.formatted(date: .abbreviated, time: .shortened)), \
            when it was recorded, and in Recently Saved.
            """
    }

    private func delete() async {
        guard let client = model.client else { return }
        do {
            try await client.deleteExport(id: export.id)
            ExportDownloader.removeDownload(of: export)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
