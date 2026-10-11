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

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show notifications while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap opens the review; "Mark Reviewed" marks it without opening the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let frigate = response.notification.request.content.userInfo["frigate"] as? [String: Any]
        guard let reviewID = frigate?["review_id"] as? String else { return }
        switch response.actionIdentifier {
        case PushNotifications.markReviewedAction:
            // Returning lets iOS suspend the app, so wait for the request.
            await model.markReviewed(ids: [reviewID])
        case UNNotificationDefaultActionIdentifier:
            await model.open(reviewID: reviewID)
        default:
            break
        }
    }
}
