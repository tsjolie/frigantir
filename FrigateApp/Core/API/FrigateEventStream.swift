import Foundation

/// Frigate's `/ws` WebSocket: pushes `{"topic": ..., "payload": ...}` messages
/// such as `reviews` (new/update/end review items), `events`, `camera_activity`
/// and `stats`. The app uses it to refresh the Review badge and lists live
/// instead of polling. Reconnects with backoff while the app is in the foreground.
@Observable
final class FrigateEventStream {
    struct Message: Sendable {
        let topic: String
        /// Usually a JSON document encoded as a string.
        let payload: String
    }

    private(set) var isConnected = false
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var handlers: [(Message) -> Void] = []

    func onMessage(_ handler: @escaping (Message) -> Void) {
        handlers.append(handler)
    }

    /// `onUnauthorized` logs in to Frigate again; it's called when the socket
    /// is refused with 401 (Frigate's login cookie expired) before reconnecting.
    func connect(url: URL, session: URLSession = .shared, onUnauthorized: (@Sendable () async -> Void)? = nil) {
        disconnect()
        loop = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let task = session.webSocketTask(with: url)
                self.task = task
                task.resume()
                // Ask Frigate to send the current state of everything right away.
                try? await task.send(.string(#"{"topic":"onConnect","payload":""}"#))
                isConnected = true

                while !Task.isCancelled {
                    guard let message = try? await task.receive() else { break }
                    attempt = 0
                    if case .string(let text) = message, let decoded = Self.decode(text) {
                        handlers.forEach { $0(decoded) }
                    }
                }

                isConnected = false
                task.cancel()
                if (task.response as? HTTPURLResponse)?.statusCode == 401, let onUnauthorized {
                    await onUnauthorized()
                }
                attempt += 1
                try? await Task.sleep(for: .seconds(min(30, pow(2, Double(attempt)))))
            }
        }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
    }

    nonisolated static func decode(_ text: String) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let topic = object["topic"] as? String else { return nil }
        let payload: String
        switch object["payload"] {
        case let string as String: payload = string
        case let value?: payload = (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        case nil: payload = ""
        }
        return Message(topic: topic, payload: payload)
    }
}
