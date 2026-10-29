import UserNotifications

/// Adds the review's thumbnail to a notification before iOS shows it.
///
/// iOS runs this extension for pushes with `mutable-content: 1` and gives it
/// about 30 seconds. If the image can't be fetched in time (or at all), the
/// notification is shown without it rather than not at all.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    // iOS may call `serviceExtensionTimeWillExpire` while the download finishes,
    // so delivery is guarded by a lock and happens exactly once.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var download: URLSessionDataTask?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        lock.withLock {
            self.contentHandler = contentHandler
            self.content = content
        }
        guard let url = NotificationThumbnail.url(from: request.content.userInfo) else {
            deliver()
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: url) { [self] data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let attachment = NotificationThumbnail.attachment(from: data) {
                lock.withLock { self.content?.attachments = [attachment] }
            }
            deliver()
        }
        lock.withLock { download = task }
        task.resume()
        // Releases the session (and its delegate queue) once the download ends.
        session.finishTasksAndInvalidate()
    }

    override func serviceExtensionTimeWillExpire() {
        lock.withLock { download }?.cancel()
        deliver()
    }

    private func deliver() {
        let (handler, content) = lock.withLock {
            defer { contentHandler = nil }
            return (contentHandler, self.content)
        }
        if let handler, let content { handler(content) }
    }
}
