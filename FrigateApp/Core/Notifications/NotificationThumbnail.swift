import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Builds the image attachment for a review notification. Shared by the
/// Notification Service Extension (which downloads the image) and the unit tests.
///
/// The notification server puts a signed, short-lived link to the review's
/// thumbnail in the push (`frigate.thumbnail_url`), served by the server itself
/// so it works away from home even when Frigate is only reachable on the LAN.
nonisolated enum NotificationThumbnail {
    static func url(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let frigate = userInfo["frigate"] as? [String: Any],
              let string = frigate["thumbnail_url"] as? String,
              let url = URL(string: string),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// Frigate's thumbnails are WebP, which notification attachments don't
    /// accept, so the image is re-encoded as JPEG. `nil` if it isn't an image.
    static func attachment(from data: Data,
                           directory: URL = FileManager.default.temporaryDirectory) -> UNNotificationAttachment? {
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let file = directory.appending(path: "\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: file)
            return try UNNotificationAttachment(identifier: "thumbnail", url: file, options: [
                UNNotificationAttachmentOptionsTypeHintKey: UTType.jpeg.identifier,
            ])
        } catch {
            return nil
        }
    }
}
