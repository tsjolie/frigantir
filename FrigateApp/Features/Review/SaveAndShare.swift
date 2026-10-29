import Photos
import UIKit

/// Saves videos to the photo library.
nonisolated enum PhotoLibrary {
    struct SaveError: LocalizedError {
        var errorDescription: String? { "Photos couldn't add this video." }
    }

    /// Nonisolated: Photos runs the change block on its own queue. Returns the
    /// new asset's identifier.
    @discardableResult
    static func saveVideo(_ file: URL) async throws -> String {
        // Set inside the change block, read after it finishes.
        nonisolated(unsafe) var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)?
                .placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else { throw SaveError() }
        return identifier
    }
}

/// The system share sheet, presented with UIKit over whatever is on screen.
/// (Wrapped in a SwiftUI sheet, its activities, such as Save to Files and
/// Save Video, can fail; on iPad it also needs a popover anchor.)
enum ShareSheet {
    static func present(_ items: [Any], completion: @escaping @MainActor (Error?) -> Void = { _ in }) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else {
            exportLog.error("No window to present the share sheet from")
            return
        }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        controller.completionWithItemsHandler = { activity, completed, _, error in
            let name = activity?.rawValue ?? "none"
            if let error {
                exportLog.error("Share via \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } else {
                exportLog.info("Share via \(name, privacy: .public) completed: \(completed)")
            }
            Task { @MainActor in completion(error) }
        }
        top.present(controller, animated: true)
    }
}
