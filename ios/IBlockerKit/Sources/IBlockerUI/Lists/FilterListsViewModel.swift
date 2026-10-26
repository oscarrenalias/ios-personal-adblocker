#if os(iOS)
import Foundation
import Observation
import IBlockerKit

@MainActor
@Observable
public final class FilterListsViewModel {

    public private(set) var state: FilterListState
    public private(set) var isUpdating = false
    public private(set) var lastCompileStats: CompileStats?
    /// Set by full update runs only; shown at the bottom of the Lists tab.
    public var errorMessage: String?
    /// Set by the add-custom-list flow only; shown in the add sheet.
    public var addListError: String?

    private let paths: AppGroupPaths
    private let store: FilterListStore
    private let log = Log(category: "lists")

    public init(paths: AppGroupPaths, store: FilterListStore = AppEnvironment.listStore) {
        self.paths = paths
        self.store = store
        self.state = FilterListState.load(from: paths.filterStateURL)
    }

    public func metadata(for sourceID: String) -> FilterListMetadata {
        state.metadata[sourceID] ?? FilterListMetadata()
    }

    // MARK: - Sources

    public func setSource(id: String, enabled: Bool) async {
        guard state.sources.contains(where: { $0.id == id }) else { return }
        await apply { state in
            guard let index = state.sources.firstIndex(where: { $0.id == id }) else { return }
            state.sources[index].enabled = enabled
        }
        if SeedRules.bundledText(for: id) != nil {
            // Bundled sources need no download — recompile is enough.
            await compileOnly()
        } else {
            await updateAndCompile(force: false)
        }
    }

    /// Sources the list screen shows. Hidden sources stay in `state` so their
    /// stored enablement survives the flag being flipped back.
    public var visibleSources: [FilterListSource] {
        state.sources.filter { !FeatureFlags.isHidden(sourceID: $0.id) }
    }

    /// The "Block Apple tracker relay" bundled source, surfaced in Settings
    /// as the Private Relay compatibility choice.
    public var isRelayBlockEnabled: Bool {
        state.sources.first { $0.id == SeedRules.relaySourceID }?.enabled ?? true
    }

    public func setRelayBlock(enabled: Bool) async {
        await setSource(id: SeedRules.relaySourceID, enabled: enabled)
    }

    /// Validates by test-downloading before accepting the source.
    public func addCustomSource(name: String, url: URL) async -> Bool {
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        let source = FilterListSource(id: id, name: name, url: url, enabled: true, isBuiltIn: false)
        do {
            try await store.mutate { state in state.sources.append(source) }
        } catch {
            addListError = "Could not save the new list"
            log.notice("custom list \(id) add failed: could not save")
            return false
        }
        let summary = await store.update(sourceIDs: [id], force: false, trigger: .user)
        guard summary.updatedSourceIDs.contains(id) else {
            let reason = summary.rejectedReasons[id] ?? summary.failedSourceIDs[id] ?? "Download failed"
            addListError = reason
            log.notice("custom list \(id) add failed: \(reason)")
            // Roll back the probe so a rejected source never lingers.
            try? await store.mutate { state in
                state.sources.removeAll { $0.id == id }
                state.metadata[id] = nil
            }
            try? FileManager.default.removeItem(at: paths.cachedListURL(sourceID: id))
            reloadState()
            return false
        }
        reloadState()
        log.info("custom list \(id) added: \(state.metadata[id]?.entryCount ?? 0) rules")
        await compileOnly()
        return true
    }

    public func removeSource(id: String) async {
        guard let index = state.sources.firstIndex(where: { $0.id == id }), !state.sources[index].isBuiltIn else { return }
        try? FileManager.default.removeItem(at: paths.cachedListURL(sourceID: id))
        await apply { state in
            state.sources.removeAll { $0.id == id }
            state.metadata[id] = nil
        }
        await compileOnly()
    }

    // MARK: - Allow / deny

    public func addAllow(_ domain: String) async {
        guard let normalized = DomainValidator.normalize(domain),
              !state.userAllowlist.contains(normalized) else { return }
        await apply { $0.userAllowlist.append(normalized) }
        await compileOnly()
    }

    public func addDeny(_ domain: String) async {
        guard let normalized = DomainValidator.normalize(domain),
              !state.userDenylist.contains(normalized) else { return }
        await apply { $0.userDenylist.append(normalized) }
        await compileOnly()
    }

    public func removeAllow(_ domain: String) async {
        await apply { $0.userAllowlist.removeAll { $0 == domain } }
        await compileOnly()
    }

    public func removeDeny(_ domain: String) async {
        await apply { $0.userDenylist.removeAll { $0 == domain } }
        await compileOnly()
    }

    // MARK: - Update & compile

    public var onRulesChanged: (@MainActor () async -> Void)?

    public func updateAndCompile(force: Bool, trigger: FilterListStore.UpdateTrigger = .user) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }

        let summary = await store.updateAll(force: force, trigger: trigger)
        reloadState()

        if !summary.failedSourceIDs.isEmpty {
            let names = summary.failedSourceIDs.keys.sorted().joined(separator: ", ")
            errorMessage = "Update failed for: \(names)"
        } else {
            errorMessage = nil
        }

        // The store recompiles when anything changed; refresh stats and notify.
        if let stats = try? await store.compile() {
            lastCompileStats = stats
        }
        reloadState()
        await onRulesChanged?()
        AppEnvironment.settings.lastListUpdate = Date()
    }

    /// Recompiles from cached list files; the store runs it off the main actor.
    public func compileOnly() async {
        if let stats = try? await store.compile() {
            lastCompileStats = stats
            reloadState()
            await onRulesChanged?()
        }
    }

    /// Recompiles immediately when the app's built-in rules changed since
    /// the on-device blob was produced (app updates), or the blob is
    /// missing. Cheap no-op otherwise. Closes the gap where an updated app
    /// ships new seed rules but the old blob keeps serving the tunnel.
    public func ensureFreshCompile() async {
        let blobMissing = !FileManager.default.fileExists(atPath: paths.blocklistURL.path)
        let formatMismatch = state.compiledFormatVersion != CompiledBlocklist.formatVersion
        if formatMismatch {
            let old = state.compiledFormatVersion.map(String.init) ?? "none"
            log.notice("recompiling: compiled format \(old) → \(CompiledBlocklist.formatVersion)")
        }
        if blobMissing || formatMismatch || state.compiledSeedVersion != SeedRules.version {
            await compileOnly()
        }
    }

    /// Foreground staleness check: BGAppRefresh is best-effort, so refresh
    /// whenever the app comes forward with lists older than a day.
    public func refreshIfStale() async {
        let last = AppEnvironment.settings.lastListUpdate ?? .distantPast
        if Date().timeIntervalSince(last) > 24 * 3600 {
            await updateAndCompile(force: false, trigger: .staleCheck)
        }
    }

    /// Applies a state edit through the store, then refreshes the local mirror.
    private func apply(_ body: (inout FilterListState) -> Void) async {
        try? await store.mutate { state in body(&state) }
        reloadState()
    }

    private func reloadState() {
        state = FilterListState.load(from: paths.filterStateURL)
    }
}
#endif
