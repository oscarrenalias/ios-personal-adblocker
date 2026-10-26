#if os(iOS)
import SwiftUI
import IBlockerKit

public struct DashboardView: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(QueryLogViewModel.self) private var log
    @Environment(\.switchToSettings) private var switchToSettings
    @State private var fileStats = BlockerStats()
    @State private var compiledRuleCount: UInt64 = 0

    private static let uiLog = Log(category: "ui")

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    ProtectionToggle()
                        .padding(.top, 24)

                    statusLine

                    pauseControls

                    countersRow

                    StatsChartView()

                    if let error = tunnel.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 32)
            }
            .background(DashboardBackground())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await refreshLoop()
            }
        }
    }

    private var statusLine: some View {
        Group {
            switch tunnel.state {
            case .connected:
                connectedStatus
            case .connecting:
                Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .disconnecting:
                Label("Stopping…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .disconnected:
                Label("Not protected", systemImage: "shield.slash")
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Label("Tap the shield to set up protection", systemImage: "hand.tap")
                    .foregroundStyle(.secondary)
            case .permissionNeeded:
                Label("VPN permission needed — tap the shield", systemImage: "lock.shield")
                    .foregroundStyle(.orange)
            case .unknown:
                Label("Checking status…", systemImage: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium))
        .onChange(of: resolverPresentation.tone) { old, new in
            // Fires on tone change only (not per poll); skip leaving the connected state.
            guard tunnel.state == .connected else { return }
            Self.uiLog.info("Resolver status tone \(String(describing: old)) -> \(String(describing: new)): \(resolverPresentation.mainLine)")
        }
    }

    private var resolverPresentation: ResolverStatusPresentation {
        ResolverStatusPresentation(
            tunnelConnected: tunnel.state == .connected,
            resolverStatus: tunnel.runtimeStats?.resolverStatus
        )
    }

    private var connectedStatus: some View {
        let presentation = resolverPresentation
        return VStack(spacing: 4) {
            Label(presentation.mainLine, systemImage: presentation.icon)
                .foregroundStyle(color(for: presentation.tone))
                .multilineTextAlignment(.center)
            if let caption = presentation.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if presentation.showsDNSSettingsButton {
                Button("DNS settings") {
                    Self.uiLog.debug("DNS settings tapped: \(presentation.mainLine) (\(String(describing: presentation.tone)))")
                    switchToSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal)
    }

    private func color(for tone: ResolverStatusPresentation.Tone) -> Color {
        switch tone {
        case .positive: .green
        case .warning: .orange
        case .critical: .red
        case .neutral: .secondary
        }
    }

    @ViewBuilder
    private var pauseControls: some View {
        if tunnel.state == .connected {
            if let until = tunnel.pausedUntil, until > Date() {
                VStack(spacing: 6) {
                    Label {
                        Text("Paused — resumes \(until, style: .relative)")
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)

                    Button("Resume now") {
                        Task { await tunnel.resume() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Menu {
                    Button("Pause 5 minutes") { Task { await tunnel.pause(minutes: 5) } }
                    Button("Pause 15 minutes") { Task { await tunnel.pause(minutes: 15) } }
                    Button("Pause 1 hour") { Task { await tunnel.pause(minutes: 60) } }
                } label: {
                    Label("Pause blocking", systemImage: "pause.circle")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var countersRow: some View {
        HStack(spacing: 12) {
            CounterTile(
                title: "Blocked today",
                value: todayBlocked,
                symbol: "nosign",
                tint: .red
            )
            CounterTile(
                title: "Total blocked",
                value: totalBlocked,
                symbol: "shield.fill",
                tint: .blue
            )
            CounterTile(
                title: "Rules",
                value: rulesTile.value,
                caption: rulesTile.caption,
                symbol: "list.number",
                tint: .purple
            )
        }
        .padding(.horizontal)
    }

    private var todayBlocked: UInt64 {
        fileStats.counters(day: BlockerStats.dayKey()).blocked
    }

    private var totalBlocked: UInt64 {
        max(tunnel.runtimeStats?.blockedQueries ?? 0, fileStats.totalBlocked)
    }

    private var rulesTile: RulesTilePresentation {
        RulesTilePresentation(liveCount: tunnel.runtimeStats?.blocklistEntryCount, compiledCount: compiledRuleCount)
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            await tunnel.refreshStats()
            fileStats = StatsPersistence.load(from: AppEnvironment.paths.statsURL)
            compiledRuleCount = UInt64((try? CompiledBlocklistView(contentsOf: AppEnvironment.paths.blocklistURL))?.count ?? 0)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

struct CounterTile: View {
    let title: String
    let value: UInt64?
    var caption: String?
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value?.formatted(.number.notation(.compactName)) ?? "—")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct DashboardBackground: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }
}
#endif
