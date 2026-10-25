import Foundation

/// Sole owner of load/modify/save of `FilterListState`. The actor runs one
/// call at a time, so concurrent mutations and compiles can't lose updates.
public actor FilterListStore {
    public typealias Compiler = @Sendable (inout FilterListState, AppGroupPaths) throws -> CompileStats

    private let paths: AppGroupPaths
    private let compiler: Compiler
    private let updater: FilterListUpdater
    private let log = Log(category: "lists")
    private var inFlightUpdate: Task<UpdateSummary, Never>?

    /// What started an update run; logged only.
    public enum UpdateTrigger: String, Sendable {
        case user, background, shortcut
        case staleCheck = "stale-check"
    }

    /// `paths` locates the state file and compiled blobs (use a temp dir in
    /// tests); `compiler` defaults to `BlocklistCompiler`; `fetch` is the
    /// network layer for `updateAll` (tests inject a fake).
    public init(paths: AppGroupPaths,
                compiler: @escaping Compiler = { state, paths in
                    try BlocklistCompiler.compile(state: &state, paths: paths)
                },
                fetch: @escaping FilterListUpdater.Fetch) {
        self.paths = paths
        self.compiler = compiler
        self.updater = FilterListUpdater(paths: paths, fetch: fetch)
    }

    #if canImport(Darwin) || canImport(FoundationNetworking)
    /// Production store: downloads through `session`.
    public init(paths: AppGroupPaths,
                compiler: @escaping Compiler = { state, paths in
                    try BlocklistCompiler.compile(state: &state, paths: paths)
                },
                session: URLSession = .shared) {
        self.paths = paths
        self.compiler = compiler
        self.updater = FilterListUpdater(paths: paths, session: session)
    }
    #endif

    /// Fetches, validates and saves every enabled list, then recompiles if
    /// anything changed. A call that arrives while a run is in progress
    /// awaits that run and returns its summary without downloading again.
    public func updateAll(force: Bool = false, trigger: UpdateTrigger) async -> UpdateSummary {
        if let running = inFlightUpdate {
            log.debug("update joined in-flight run (trigger \(trigger.rawValue))")
            return await running.value
        }
        let task = Task { await self.runUpdate(force: force, trigger: trigger) }
        inFlightUpdate = task
        let summary = await task.value
        inFlightUpdate = nil
        return summary
    }

    private func runUpdate(force: Bool, trigger: UpdateTrigger) async -> UpdateSummary {
        let started = Date()
        log.info("update started (trigger \(trigger.rawValue), force \(force))")

        // Fetch against a snapshot so the actor stays free for mutate() during
        // the downloads; only the touched metadata is merged back afterwards.
        var snapshot = FilterListState.load(from: paths.filterStateURL)
        let summary = await updater.update(state: &snapshot, force: force)
        let touched = Set(summary.updatedSourceIDs + summary.unchangedSourceIDs
                          + summary.rejectedSourceIDs + Array(summary.failedSourceIDs.keys))
        do {
            try mutate { state in
                for id in touched { state.metadata[id] = snapshot.metadata[id] }
            }
            if summary.anyChanged { try compile() }
        } catch {
            log.error("update post-processing failed: \(error)")
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log.info("update finished (trigger \(trigger.rawValue), \(ms) ms): \(summary.updatedSourceIDs.count) updated, \(summary.unchangedSourceIDs.count) unchanged, \(summary.rejectedSourceIDs.count) rejected, \(summary.failedSourceIDs.count) failed")
        return summary
    }

    /// Loads the current state, applies `body`, saves, and returns the
    /// body's result. If `body` throws, nothing is saved.
    @discardableResult
    public func mutate<T>(_ body: (inout FilterListState) throws -> T) throws -> T {
        var state = FilterListState.load(from: paths.filterStateURL)
        let result = try body(&state)
        do {
            try state.save(to: paths.filterStateURL)
        } catch {
            log.error("filter list state save failed: \(error)")
            throw error
        }
        return result
    }

    /// Loads the state, recompiles the blocklist blobs, and saves the
    /// updated state (generation, entry counts).
    @discardableResult
    public func compile() throws -> CompileStats {
        var state = FilterListState.load(from: paths.filterStateURL)
        let stats: CompileStats
        do {
            stats = try compiler(&state, paths)
        } catch {
            log.error("compile failed: \(error)")
            throw error
        }
        try state.save(to: paths.filterStateURL)
        log.info("compiled lists: \(stats.blockedEntryCount) blocked, generation \(stats.generation)")
        return stats
    }
}
