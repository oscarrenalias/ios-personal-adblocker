#if os(iOS)
import Foundation
import IBlockerKit

/// Process-wide accessors resolved from the app's Info.plist, so no source
/// file hardcodes the App Group or bundle identifiers.
public enum AppEnvironment {
    public static var groupID: String {
        AppGroupPaths.groupID(from: .main) ?? "group.invalid.adblocker"
    }

    public static var paths: AppGroupPaths {
        AppGroupPaths(groupID: groupID)
            ?? AppGroupPaths(containerURL: FileManager.default.temporaryDirectory)
    }

    /// The single shared store; all list mutations and updates go through it.
    public static let listStore = FilterListStore(
        paths: paths,
        notifier: NotificationPoster(
            preferences: { StatusNotificationPreferences(settings: AppEnvironment.settings) }
        ),
        settings: settings
    )

    public static var settings: SharedSettings {
        SharedSettings(groupID: groupID) ?? SharedSettings(defaults: .standard)
    }

    public static var refreshTaskID: String {
        (Bundle.main.bundleIdentifier ?? "net.renalias.adblocker") + ".refresh"
    }

    public static var tunnelBundleID: String {
        (Bundle.main.bundleIdentifier ?? "net.renalias.adblocker") + ".tunnel"
    }

    public static var contentBlockerBundleID: String {
        (Bundle.main.bundleIdentifier ?? "net.renalias.adblocker") + ".blocker"
    }
}
#endif
