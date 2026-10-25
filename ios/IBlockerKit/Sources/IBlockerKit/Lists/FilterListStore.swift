import Foundation

/// Sole owner of load/modify/save of `FilterListState`. The actor runs one
/// call at a time, so concurrent mutations and compiles can't lose updates.
public actor FilterListStore {
    public typealias Compiler = @Sendable (inout FilterListState, AppGroupPaths) throws -> CompileStats

    private let paths: AppGroupPaths
    private let compiler: Compiler
    private let log = Log(category: "lists")

    /// `paths` locates the state file and compiled blobs (use a temp dir in
    /// tests); `compiler` defaults to `BlocklistCompiler`.
    public init(paths: AppGroupPaths,
                compiler: @escaping Compiler = { state, paths in
                    try BlocklistCompiler.compile(state: &state, paths: paths)
                }) {
        self.paths = paths
        self.compiler = compiler
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
