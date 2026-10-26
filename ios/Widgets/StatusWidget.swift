import WidgetKit
import SwiftUI
import IBlockerKit

struct StatusEntry: TimelineEntry {
    let date: Date
    let blockedToday: UInt64
    let totalBlocked: UInt64
    let active: Bool
    let paused: Bool
    let encryption: WidgetEncryptionPresentation
}

private let widgetsLog = Log(category: "widgets")

/// App Group accessors resolved from the widget bundle's Info.plist.
enum WidgetEnvironment {
    static var settings: SharedSettings? {
        guard let groupID = AppGroupPaths.groupID(from: .main) else { return nil }
        return SharedSettings(groupID: groupID)
    }

    static var statsURL: URL? {
        guard let groupID = AppGroupPaths.groupID(from: .main),
              let paths = AppGroupPaths(groupID: groupID) else { return nil }
        return paths.statsURL
    }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(
            date: Date(), blockedToday: 1234, totalBlocked: 98765, active: true, paused: false,
            encryption: WidgetEncryptionPresentation(
                protectionActive: true,
                paused: false,
                resolverStatus: .alternative(name: "Cloudflare", encrypted: true)
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let next = Date(timeIntervalSinceNow: 15 * 60)
        completion(Timeline(entries: [makeEntry()], policy: .after(next)))
    }

    private func makeEntry() -> StatusEntry {
        let stats = WidgetEnvironment.statsURL.map { StatsPersistence.load(from: $0) } ?? BlockerStats()
        let settings = WidgetEnvironment.settings
        let now = Date()
        let active = settings?.protectionActive ?? false
        let paused = (settings?.pausedUntil ?? .distantPast) > now
        let encryption = WidgetEncryptionPresentation(
            protectionActive: active,
            paused: paused,
            resolverStatus: settings?.widgetResolverStatus
        )
        widgetsLog.debug("status entry: active=\(active) paused=\(paused) encryption=\(encryption.state.logName)")
        return StatusEntry(
            date: now,
            blockedToday: stats.counters(day: BlockerStats.dayKey()).blocked,
            totalBlocked: stats.totalBlocked,
            active: active,
            paused: paused,
            encryption: encryption
        )
    }
}

struct StatusWidgetView: View {
    var entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("\(entry.blockedToday) blocked")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("Personal AdBlocker", systemImage: statusSymbol)
                    .font(.headline)
                Text("\(entry.blockedToday.formatted()) blocked today")
                    .font(.caption)
                encryptionLine(colored: false)
            }
        case .accessoryCircular:
            Gauge(value: 0) {
                Image(systemName: statusSymbol)
            } currentValueLabel: {
                Text(entry.blockedToday.formatted(.number.notation(.compactName)))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                    Spacer()
                }
                encryptionLine(colored: true)
                Spacer()
                Text(entry.blockedToday.formatted(.number.notation(.compactName)))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.red)
                Text("blocked today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(entry.totalBlocked.formatted(.number.notation(.compactName))) all time")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Encryption symbol and text on one tail-truncated line; empty when the
    /// presentation has nothing to show (hidden or unknown).
    @ViewBuilder
    private func encryptionLine(colored: Bool) -> some View {
        if let symbol = entry.encryption.symbol, let text = entry.encryption.text {
            Label(text, systemImage: symbol)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(colored ? AnyShapeStyle(encryptionColor) : AnyShapeStyle(.primary))
        }
    }

    private var encryptionColor: Color {
        switch entry.encryption.tone {
        case .positive: return .green
        case .warning: return .orange
        case .critical: return .red
        case nil: return .secondary
        }
    }

    private var statusSymbol: String {
        if entry.paused { return "pause.circle.fill" }
        return entry.active ? "checkmark.shield.fill" : "shield.slash"
    }

    private var statusColor: Color {
        if entry.paused { return .orange }
        return entry.active ? .green : .secondary
    }

    private var statusText: String {
        if entry.paused { return "Paused" }
        return entry.active ? "Protected" : "Off"
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.statusWidget, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Personal AdBlocker")
        .description("Ads blocked today and protection status.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryInline, .accessoryRectangular, .accessoryCircular,
        ])
    }
}
