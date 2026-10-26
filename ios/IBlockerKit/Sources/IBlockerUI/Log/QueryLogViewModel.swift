#if os(iOS)
import Foundation
import Observation
import IBlockerKit

@MainActor
@Observable
public final class QueryLogViewModel {

    public enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case blocked = "Blocked"
        case allowed = "Allowed"
        public var id: String { rawValue }
    }

    public private(set) var records: [QueryLogRecord] = []
    public var searchText = ""
    public var filter: Filter = .all

    /// Optional hook awaited before each poll reads the ring (e.g. to ask the
    /// extension to flush pending records). Polling works without it.
    public var flushHook: (@MainActor () async -> Void)?

    private let reader: QueryLogRingReader
    private var cursor: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var gate = PollingGate()
    private static let uiLog = Log(category: "ui")
    private let maxRecords = 4000

    public init(paths: AppGroupPaths) {
        self.reader = QueryLogRingReader(url: paths.queryLogURL)
        readRing()
    }

    /// 1 Hz polling while at least one view (Log tab, dashboard chart) is
    /// visible and the scene is active. Calls are reference-counted; pair each
    /// with `stopPolling()`.
    public func startPolling() {
        gate.register()
        syncPollTask()
    }

    public func stopPolling() {
        gate.unregister()
        syncPollTask()
    }

    /// Suspends polling (and the tunnel flush IPC it triggers) while the scene
    /// isn't active; resumes when it is, if pollers are still registered.
    public func setSceneActive(_ active: Bool, phase: String = "") {
        guard gate.isSceneActive != active else { return }
        let wasRunning = pollTask != nil
        gate.setActive(active)
        syncPollTask()
        if wasRunning && pollTask == nil {
            Self.uiLog.debug("polling paused (scene \(phase))")
        } else if !wasRunning && pollTask != nil {
            Self.uiLog.debug("polling resumed")
        }
    }

    private func syncPollTask() {
        if gate.shouldRun {
            guard pollTask == nil else { return }
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    /// Awaits the flush hook (if any), then reads new records from the ring.
    public func poll() async {
        if let flushHook { await flushHook() }
        readRing()
    }

    private func readRing() {
        let (new, newCursor) = reader.read(since: cursor)
        guard newCursor != cursor else { return }
        cursor = newCursor
        records.append(contentsOf: new)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
    }

    public var filtered: [QueryLogRecord] {
        var result = records
        switch filter {
        case .all: break
        case .blocked: result = result.filter { $0.verdict == .blocked }
        case .allowed: result = result.filter { $0.verdict != .blocked }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { $0.domain.contains(query) }
        }
        return Array(result.reversed())
    }

    /// Blocked count per hour of the local day, for the dashboard chart.
    public var blockedPerHourToday: [(hour: Int, blocked: Int)] {
        var buckets = [Int](repeating: 0, count: 24)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for record in records where record.verdict == .blocked {
            let date = record.date
            guard date >= today else { continue }
            buckets[calendar.component(.hour, from: date)] += 1
        }
        return (0..<24).map { ($0, buckets[$0]) }
    }

    public var topBlockedDomains: [(domain: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in records where record.verdict == .blocked {
            counts[record.domain, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }
}
#endif
