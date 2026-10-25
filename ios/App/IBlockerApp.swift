import SwiftUI
import IBlockerKit
import IBlockerUI

@main
struct IBlockerApp: App {
    init() {
        ListRefreshScheduler.register()
        Log.setVerbose(AppEnvironment.settings.verboseLoggingUntil != nil)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
