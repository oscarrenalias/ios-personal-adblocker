#if os(iOS)
import SwiftUI
import IBlockerKit
import Observation

/// Carries a notification-tap destination from the app's notification
/// delegate to `RootView`. A shared instance, so a tap that cold-launches the
/// app is still picked up once the view appears.
@MainActor @Observable
public final class NotificationTabRouter {
    public static let shared = NotificationTabRouter()

    public private(set) var pendingTab: StatusNotificationKind.Tab?

    public func route(to tab: StatusNotificationKind.Tab) {
        pendingTab = tab
    }

    fileprivate func consume() -> RootTab? {
        defer { pendingTab = nil }
        switch pendingTab {
        case .dashboard: return .dashboard
        case .lists: return .lists
        case nil: return nil
        }
    }
}

/// Identifies each top-level tab in `RootView`.
enum RootTab: Hashable {
    case dashboard, log, lists, settings
}

private struct SwitchToSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Call to switch the root TabView to the Settings tab.
    var switchToSettings: @MainActor () -> Void {
        get { self[SwitchToSettingsKey.self] }
        set { self[SwitchToSettingsKey.self] = newValue }
    }
}

/// Rate limiter for the query-log flush hook.
@MainActor
private final class FlushThrottle {
    private let interval: TimeInterval
    private var last: Date = .distantPast

    init(interval: TimeInterval) { self.interval = interval }

    func shouldFire(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

public struct RootView: View {
    @State private var selectedTab: RootTab = .dashboard
    @State private var tunnel = TunnelController()
    @State private var lists: FilterListsViewModel
    @State private var log: QueryLogViewModel
    @State private var showOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let router = NotificationTabRouter.shared

    public init() {
        let paths = AppEnvironment.paths
        try? paths.ensureDirectories()
        _lists = State(initialValue: FilterListsViewModel(paths: paths))
        _log = State(initialValue: QueryLogViewModel(paths: paths))
        _showOnboarding = State(initialValue: !AppEnvironment.settings.onboardingComplete)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Dashboard", systemImage: "shield.lefthalf.filled", value: RootTab.dashboard) {
                DashboardView()
            }
            Tab("Log", systemImage: "list.bullet.rectangle.portrait", value: RootTab.log) {
                QueryLogView()
            }
            Tab("Lists", systemImage: "checklist", value: RootTab.lists) {
                FilterListsView()
            }
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(tunnel)
        .environment(lists)
        .environment(log)
        .environment(\.switchToSettings, { selectedTab = .settings })
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environment(tunnel)
                .environment(lists)
        }
        .task {
            lists.onRulesChanged = { [weak tunnel] in
                await tunnel?.reloadRules()
            }
            // Polling runs at 1 Hz; ask the tunnel to flush at most every 2 s.
            // flushQueryLog is itself a no-op when not connected.
            let throttle = FlushThrottle(interval: 2)
            log.flushHook = { [weak tunnel] in
                guard throttle.shouldFire() else { return }
                await tunnel?.flushQueryLog()
            }
            await lists.ensureFreshCompile()
        }
        .onChange(of: router.pendingTab, initial: true) {
            if let tab = router.consume() {
                showOnboarding = false
                selectedTab = tab
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            log.setSceneActive(phase == .active, phase: String(describing: phase))
            if phase == .active {
                Task {
                    await tunnel.refresh()
                    await lists.refreshIfStale()
                }
                ListRefreshScheduler.schedule()
            }
        }
    }
}
#endif
