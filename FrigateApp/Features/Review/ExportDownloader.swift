import Foundation
import Observation
import os

let exportLog = Logger(subsystem: "net.sjolie.frigateapp", category: "exports")

/// Downloads an export's video into the app's caches, with progress. A
/// finished download is reused, so sharing again doesn't download again.
@Observable
final class ExportDownloader {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case finished(URL)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var downloadedFile: URL? {
        if case .finished(let url) = state { url } else { nil }
    }

    /// Where an export's download is kept: a folder per export, so the file
    /// itself can carry the export's name when shared.
    nonisolated static func file(for export: FrigateExport) -> URL {
        URL.cachesDirectory
            .appending(path: "Exports", directoryHint: .isDirectory)
            .appending(path: export.id, directoryHint: .isDirectory)
            .appending(path: export.fileName)
    }

    static func removeDownload(of export: FrigateExport) {
        try? FileManager.default.removeItem(at: file(for: export).deletingLastPathComponent())
    }

    func checkForDownload(of export: FrigateExport) {
        let file = Self.file(for: export)
        if FileManager.default.fileExists(atPath: file.path) { state = .finished(file) }
    }

    func download(_ export: FrigateExport, client: FrigateClient,
                  completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        let destination = Self.file(for: export)
        if FileManager.default.fileExists(atPath: destination.path) {
            exportLog.info("Using the earlier download of \(export.id, privacy: .public)")
            state = .finished(destination)
            completion(.success(destination))
            return
        }
        let request = URLRequest(url: client.exportVideoURL(export))
        start(request, to: destination) { [weak self] result in
            guard let self else { return }
            // The auth cookie may have expired; log in once and try again.
            guard case .failure(let error) = result, case .unauthorized? = error as? FrigateClient.ClientError,
                  client.username?.isEmpty == false
            else { return finish(result, completion: completion) }
            Task {
                do {
                    try await client.login()
                    self.start(request, to: destination) { self.finish($0, completion: completion) }
                } catch {
                    self.finish(.failure(error), completion: completion)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        observation = nil
        if case .downloading = state { state = .idle }
    }

    private func start(_ request: URLRequest, to destination: URL,
                       completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
            // The temporary file is deleted when this handler returns, so move it now.
            let result = Self.store(location, response: response, error: error, at: destination)
            Task { @MainActor in completion(result) }
        }
        observation = Self.observeProgress(of: task) { [weak self] fraction in
            guard let self, case .downloading = state else { return }
            state = .downloading(fraction)
        }
        self.task = task
        task.resume()
    }

    /// Nonisolated: KVO calls the handler on URLSession's queue; updates hop
    /// back to the main actor.
    private nonisolated static func observeProgress(
        of task: URLSessionDownloadTask, update: @escaping @MainActor @Sendable (Double) -> Void
    ) -> NSKeyValueObservation {
        task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in update(fraction) }
        }
    }

    private func finish(_ result: Result<URL, Error>, completion: (Result<URL, Error>) -> Void) {
        task = nil
        observation = nil
        switch result {
        case .success(let url):
            exportLog.info("Downloaded \(url.lastPathComponent, privacy: .public)")
            state = .finished(url)
        case .failure(let error):
            // Cancelling isn't an error worth showing.
            if (error as? URLError)?.code == .cancelled {
                state = .idle
                return
            }
            state = .failed(error.localizedDescription)
        }
        completion(result)
    }

    private nonisolated static func store(_ location: URL?, response: URLResponse?, error: Error?,
                                          at destination: URL) -> Result<URL, Error> {
        if let error { return .failure(error) }
        guard let location, let http = response as? HTTPURLResponse else {
            return .failure(URLError(.badServerResponse))
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            return .failure(http.statusCode == 401 ? FrigateClient.ClientError.unauthorized
                : FrigateClient.ClientError.http(http.statusCode, http.url?.path ?? ""))
        }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
            return .success(destination)
        } catch {
            return .failure(error)
        }
    }
}
