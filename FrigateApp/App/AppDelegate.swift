import UIKit
import UserNotifications

/// UIKit entry points SwiftUI doesn't offer: the push device token, and
/// notification taps and actions. Owns the app model so a notification that
/// launches the app is handled before any view exists.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PushNotifications.registerCategories()
        Task { await model.push.refreshRegistration() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.push.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.push.didFailToRegister(error)
    }
}

// The completion-handler forms, not the `async` ones: UIKit requires these
// completion handlers to be called on the main thread, and a `nonisolated async`
// implementation returns, and so calls them, on a background thread (an
// NSInternalInconsistencyException abort when a notification is tapped). These
// stay nonisolated so they're correct whichever thread iOS calls them on, and
// finish on the main actor.
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show notifications while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in completion([.banner, .list, .sound]) }
    }

    /// A tap opens the review; "Mark Reviewed" marks it without opening the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let frigate = response.notification.request.content.userInfo["frigate"] as? [String: Any]
        let reviewID = frigate?["review_id"] as? String
        let action = response.actionIdentifier
        nonisolated(unsafe) let completion = completionHandler
        Task { @MainActor in
            if let reviewID {
                switch action {
                case PushNotifications.markReviewedAction:
                    // Calling the completion handler lets iOS suspend the app,
                    // so wait for the request first.
                    await model.markReviewed(ids: [reviewID])
                case UNNotificationDefaultActionIdentifier:
                    model.open(reviewID: reviewID)
                default:
                    break
                }
            }
            completion()
        }
    }
}
