import Observation
import SwiftUI

/// A file Frigate's web UI offers to download for a review item or tracked
/// object, named the way the web UI names it.
nonisolated struct MediaDownload: Identifiable, Sendable {
    let title: String
    let systemImage: String
    let url: URL
    let fileName: String
    /// The review item or tracked object it belongs to.
    let ownerID: String
    /// A clip of something still happening grows, so it's fetched fresh.
    let isFinal: Bool

    var id: String { fileName }

    /// Kept in the caches, so sharing again doesn't download again.
    var destination: URL {
        URL.cachesDirectory
            .appending(path: "Downloads", directoryHint: .isDirectory)
            .appending(path: ownerID, directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    /// The web UI's padding around a clip, in seconds.
    static let clipPadding: TimeInterval = 4

    /// Review items: the video, as on the web UI's review detail.
    static func options(for item: ReviewItem, client: FrigateClient) -> [MediaDownload] {
        let span = item.clipSpan
        return [MediaDownload(
            title: "Download Video", systemImage: "film",
            url: client.recordingClipURL(camera: item.camera, start: span.start, end: span.end),
            fileName: "\(item.camera)_\(fileTimestamp(item.startDate)).mp4",
            ownerID: item.id, isFinal: !item.isInProgress)]
    }

    /// Tracked objects: what the web UI's Explore menu offers.
    static func options(for object: TrackedObject, client: FrigateClient) -> [MediaDownload] {
        var options: [MediaDownload] = []
        if object.hasClip {
            let end = object.endTime.map(Date.init(timeIntervalSince1970:)) ?? .now
            options.append(MediaDownload(
                title: "Download Video", systemImage: "film",
                url: client.recordingClipURL(camera: object.camera,
                                             start: object.startDate.addingTimeInterval(-clipPadding),
                                             end: end.addingTimeInterval(clipPadding)),
                fileName: "\(object.camera)_\(fileTimestamp(object.startDate)).mp4",
                ownerID: object.id, isFinal: object.endTime != nil))
        }
        if object.hasSnapshot {
            options.append(MediaDownload(
                title: "Download Snapshot", systemImage: "photo",
                url: client.snapshotDownloadURL(object), fileName: "\(object.camera)_\(object.label).jpg",
                ownerID: object.id, isFinal: object.endTime != nil))
            options.append(MediaDownload(
                title: "Download Clean Snapshot", systemImage: "photo.badge.checkmark",
                url: client.cleanSnapshotURL(object), fileName: "\(object.camera)_\(object.label)-clean.webp",
                ownerID: object.id, isFinal: object.endTime != nil))
        }
        return options
    }

    /// The web UI's file-name time format, e.g. 11-11-26-15-42-07.
    static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd-yy-HH-mm-ss"
        return formatter.string(from: date)
    }
}

/// Downloads one file at a time, with progress, then opens the share sheet
/// (Save to Photos, AirDrop, Save to Files and so on).
@Observable
final class MediaDownloader {
    let downloader = ExportDownloader()
    private(set) var current: MediaDownload?
    var error: String?

    var progress: Double? {
        if case .downloading(let fraction) = downloader.state { fraction } else { nil }
    }

    func start(_ download: MediaDownload, client: FrigateClient) {
        cancel()
        error = nil
        current = download
        if !download.isFinal { try? FileManager.default.removeItem(at: download.destination) }
        exportLog.info("Downloading \(download.fileName, privacy: .public)")
        downloader.download(download.url, to: download.destination, client: client) { [weak self] result in
            guard let self else { return }
            current = nil
            switch result {
            case .success(let file):
                ShareSheet.present([file]) { [weak self] failure in
                    if let failure { self?.error = failure.localizedDescription }
                }
            case .failure(let failure):
                if (failure as? URLError)?.code == .cancelled { return }
                exportLog.error("Download failed: \(failure.localizedDescription, privacy: .public)")
                error = failure.localizedDescription
            }
        }
    }

    func cancel() {
        downloader.cancel()
        current = nil
    }
}

/// The download buttons for a menu or context menu.
struct MediaDownloadButtons: View {
    @Environment(AppModel.self) private var model
    let options: [MediaDownload]
    let downloader: MediaDownloader

    var body: some View {
        ForEach(options) { option in
            Button(option.title, systemImage: option.systemImage) {
                guard let client = model.client else { return }
                downloader.start(option, client: client)
            }
            .disabled(downloader.current != nil)
        }
    }
}

extension View {
    /// A progress bar along the bottom while a download runs, and an alert if
    /// it fails. Leaving the screen stops the download.
    func mediaDownloadStatus(_ downloader: MediaDownloader) -> some View {
        safeAreaInset(edge: .bottom) {
            if let progress = downloader.progress {
                HStack {
                    // Frigate makes clips on request and may not say how big
                    // they'll be, so there's no percentage until it does.
                    if progress > 0 {
                        ProgressView(value: progress) {
                            Text("Downloading… \(progress, format: .percent.precision(.fractionLength(0)))")
                                .font(.footnote)
                        }
                    } else {
                        ProgressView { Text("Downloading…").font(.footnote) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Cancel") { downloader.cancel() }
                        .buttonStyle(.borderless)
                }
                .padding()
                .background(.bar)
            }
        }
        .alert("Couldn't Download", isPresented: Binding(get: { downloader.error != nil },
                                                         set: { if !$0 { downloader.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloader.error ?? "")
        }
        .onDisappear { downloader.cancel() }
    }
}
