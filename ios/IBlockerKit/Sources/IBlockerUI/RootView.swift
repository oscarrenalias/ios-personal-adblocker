#if os(iOS)
import SwiftUI
import IBlockerKit

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

public struct RootView: View {
    @State private var selectedTab: RootTab = .dashboard
    @State private var tunnel = TunnelController()
    @State private var lists: FilterListsViewModel
    @State private var log: QueryLogViewModel
    @State private var showOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase

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
            await lists.ensureFreshCompile()
        }
        .onChange(of: scenePhase) { _, phase in
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
