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
    /// Scope of `inFlightUpdate`; nil means a full run over every source.
    private var inFlightScope: Set<String>?
    /// Identity of `inFlightUpdate`, so a finishing run only clears its own state.
    private var inFlightRunID = 0

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

    /// Fetches, validates and saves every enabled list, then recompiles if
    /// anything changed. A call that arrives while a run is in progress
    /// awaits that run and returns its summary without downloading again.
    public func updateAll(force: Bool = false, trigger: UpdateTrigger) async -> UpdateSummary {
        while let running = inFlightUpdate {
            if inFlightScope == nil {
                log.debug("update joined in-flight run (trigger \(trigger.rawValue))")
                return await running.value
            }
            // A partial run doesn't cover every source; wait for it, then re-check.
            // The run clears its own state before finishing, so this can't re-await it.
            _ = await running.value
        }
        return await start(scope: nil, force: force, trigger: trigger)
    }

    /// Fetches and validates only `sourceIDs`, recompiling if any changed.
    /// Serialized with every other update run: waits for one in progress.
    public func update(sourceIDs: Set<String>, force: Bool = false, trigger: UpdateTrigger) async -> UpdateSummary {
        while let running = inFlightUpdate {
            _ = await running.value
        }
        return await start(scope: sourceIDs, force: force, trigger: trigger)
    }

    /// Must be called with no run in flight and without suspending between that
    /// check and this call. The run task clears the in-flight state itself, on
    /// the actor and before producing its value, so any waiter resumed by the
    /// task's completion sees nil or a newer run, never the finished one.
    private func start(scope: Set<String>?, force: Bool, trigger: UpdateTrigger) async -> UpdateSummary {
        inFlightRunID += 1
        let runID = inFlightRunID
        let task = Task {
            let summary = await self.runUpdate(force: force, trigger: trigger, scope: scope)
            self.clearInFlight(runID: runID)
            return summary
        }
        inFlightUpdate = task
        inFlightScope = scope
        return await task.value
    }

    private func clearInFlight(runID: Int) {
        guard inFlightRunID == runID else { return }
        inFlightUpdate = nil
        inFlightScope = nil
    }

    private func runUpdate(force: Bool, trigger: UpdateTrigger, scope: Set<String>?) async -> UpdateSummary {
        let started = Date()
        log.info("update started (trigger \(trigger.rawValue), force \(force))")

        // Fetch against a snapshot so the actor stays free for mutate() during
        // the downloads; only the touched metadata is merged back afterwards.
        var snapshot = FilterListState.load(from: paths.filterStateURL)
        let summary = await updater.update(state: &snapshot, force: force, onlySourceIDs: scope)
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
