import SwiftUI
import IBlockerKit
import IBlockerUI
import UserNotifications

/// Shows status notifications while the app is in the foreground and routes
/// a tap to the tab named in the notification's userInfo.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let log = Log(category: "notify")

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let tabName = info[StatusNotificationContent.tabKey] as? String
        let tab = tabName.flatMap(StatusNotificationKind.Tab.init(rawValue:)) ?? .dashboard
        let kind = info[StatusNotificationContent.kindKey] as? String ?? "unknown"
        log.info("opened from notification kind \(kind) -> \(tab.rawValue)")
        await MainActor.run { NotificationTabRouter.shared.route(to: tab) }
    }
}

@main
struct IBlockerApp: App {
    private static let notificationDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
        ListRefreshScheduler.register()
        Log.setVerbose(AppEnvironment.settings.verboseLoggingUntil != nil)
        // Lets the tunnel tell "settings unreadable before first unlock" from
        // "settings never written".
        AppEnvironment.settings.settingsAvailable = true
        // Existing installs wrote the blobs with data protection; relax them
        // so the tunnel can read them before first unlock.
        let log = Log(category: "app")
        for failure in AppEnvironment.paths.relaxBlobProtection() {
            log.error("could not relax file protection: \(failure.fileName), error: \(failure.error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
