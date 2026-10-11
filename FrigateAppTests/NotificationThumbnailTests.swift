import Foundation
import Testing
import UIKit
@testable import FrigateApp

@Suite struct NotificationThumbnailTests {
    @Test func readsTheThumbnailLinkFromThePush() {
        let userInfo: [AnyHashable: Any] = ["frigate": [
            "review_id": "1791293688.0-abc123",
            "thumbnail_url": "https://notify.example.com/api/v1/thumbnails/1791293688.0-abc123?expires=1&sig=ab",
        ]]
        #expect(NotificationThumbnail.url(from: userInfo)?.host == "notify.example.com")
        #expect(NotificationThumbnail.url(from: ["frigate": ["test": true]]) == nil)
        #expect(NotificationThumbnail.url(from: ["frigate": ["thumbnail_url": "file:///etc/passwd"]]) == nil)
    }

    @Test func reencodesImagesAsJPEGAttachments() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 18)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        let png = try #require(image.pngData())
        let attachment = try #require(NotificationThumbnail.attachment(from: png))
        #expect(attachment.identifier == "thumbnail")
        #expect(attachment.url.pathExtension == "jpg")
    }

    @Test func ignoresDataThatIsNotAnImage() {
        #expect(NotificationThumbnail.attachment(from: Data("<html>Forbidden</html>".utf8)) == nil)
    }
}
