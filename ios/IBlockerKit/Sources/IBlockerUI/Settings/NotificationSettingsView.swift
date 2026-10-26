#if os(iOS)
import SwiftUI
import UserNotifications
import IBlockerKit

/// Master switch and per-type toggles for status notifications. Permission is
/// requested only when the master switch is turned on; a denial reverts the
/// switch and points the user at iOS Settings.
public struct NotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var masterOn = AppEnvironment.settings.notificationsEnabled
    @State private var typeStates: [NotificationType: Bool] = Dictionary(
        uniqueKeysWithValues: NotificationType.allCases.map {
            ($0, AppEnvironment.settings.isNotificationTypeEnabled($0))
        }
    )
    @State private var deniedBySystem = false
    @State private var requesting = false

    private static let log = Log(category: "notify")

    private let poster = NotificationPoster(
        preferences: { StatusNotificationPreferences(settings: AppEnvironment.settings) }
    )

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("Status notifications", isOn: masterBinding)
                    .disabled(requesting)
                if deniedBySystem {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Notifications are turned off in iOS Settings", systemImage: "bell.slash")
                            .foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }
            } footer: {
                Text("Get a notification when protection has a lasting problem. Short blips are ignored.")
            }

            if masterOn {
                Section("Notify me about") {
                    toggle(.dns, "Encrypted DNS problems")
                    toggle(.stopped, "Protection stopped")
                    toggle(.pause, "Pause ended")
                    toggle(.lists, "Blocklist problems")
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAuthorization() } }
        }
    }

    private func toggle(_ type: NotificationType, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { typeStates[type] ?? true },
            set: { setType(type, enabled: $0) }
        ))
    }

    private var masterBinding: Binding<Bool> {
        Binding(
            get: { masterOn },
            set: { setMaster($0) }
        )
    }

    private func setMaster(_ on: Bool) {
        guard on != masterOn else { return }
        guard on else {
            masterOn = false
            AppEnvironment.settings.notificationsEnabled = false
            Self.log.notice("notifications turned off")
            for kind in StatusNotificationKind.allCases where kind != .restored {
                poster.cancelPending(kind, clearedAfter: nil)
            }
            return
        }
        // Show the switch on while the system prompt is up.
        masterOn = true
        requesting = true
        Task {
            let status = await poster.authorizationStatus()
            let granted: Bool
            switch status {
            case .notDetermined: granted = await poster.requestAuthorization()
            case .denied: granted = false
            default: granted = true
            }
            requesting = false
            if granted {
                AppEnvironment.settings.notificationsEnabled = true
                deniedBySystem = false
                Self.log.notice("notifications turned on")
            } else {
                masterOn = false
                AppEnvironment.settings.notificationsEnabled = false
                deniedBySystem = true
                Self.log.notice("notifications not turned on: permission denied")
            }
        }
    }

    private func setType(_ type: NotificationType, enabled: Bool) {
        typeStates[type] = enabled
        AppEnvironment.settings.setNotificationType(type, enabled: enabled)
        Self.log.notice("notification type \(type.rawValue) turned \(enabled ? "on" : "off")")
        guard !enabled else { return }
        let prefType = Self.preferenceType(for: type)
        for kind in StatusNotificationKind.allCases where kind.preferenceType == prefType {
            poster.cancelPending(kind, clearedAfter: nil)
        }
    }

    private static func preferenceType(for type: NotificationType) -> StatusNotificationKind.PreferenceType {
        switch type {
        case .dns: .encryptedDNS
        case .stopped: .protectionStopped
        case .pause: .pauseEnded
        case .lists: .blocklists
        }
    }

    /// Shows the Settings row while the master switch is on but iOS has
    /// notifications denied (e.g. the user turned them off afterwards).
    private func refreshAuthorization() async {
        let status = await poster.authorizationStatus()
        let denied = status == .denied
        if denied && masterOn {
            masterOn = false
            AppEnvironment.settings.notificationsEnabled = false
            Self.log.notice("notifications turned off: iOS permission is denied")
        }
        deniedBySystem = denied
    }
}
#endif
