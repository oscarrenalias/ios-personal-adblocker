import SwiftUI
import IBlockerKit
import IBlockerUI

@main
struct IBlockerApp: App {
    init() {
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
