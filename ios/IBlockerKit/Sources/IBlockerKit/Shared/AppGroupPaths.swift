import Foundation

/// Canonical locations of every file shared between the app and its
/// extensions inside the App Group container.
public struct AppGroupPaths: Sendable {
    public let containerURL: URL

    public init(containerURL: URL) {
        self.containerURL = containerURL
    }

    #if canImport(Darwin)
    /// Resolves the real App Group container. The group ID is read from the
    /// bundle's `AppGroupID` Info.plist key by callers, so no target ever
    /// hardcodes it.
    public init?(groupID: String) {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        self.init(containerURL: url)
    }

    /// Group ID as stamped into Info.plist at build time from the
    /// APP_GROUP_ID build setting.
    public static func groupID(from bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: "AppGroupID") as? String
    }
    #endif

    public var blocklistURL: URL { containerURL.appendingPathComponent("blocklist.bin") }
    public var userAllowlistURL: URL { containerURL.appendingPathComponent("allowlist.bin") }
    public var userDenylistURL: URL { containerURL.appendingPathComponent("denylist.bin") }
    public var queryLogURL: URL { containerURL.appendingPathComponent("querylog.ring") }
    public var statsURL: URL { containerURL.appendingPathComponent("stats.json") }
    public var filterStateURL: URL { containerURL.appendingPathComponent("sources.json") }
    public var listsCacheDirectory: URL { containerURL.appendingPathComponent("lists", isDirectory: true) }
    public var contentBlockerJSONURL: URL { containerURL.appendingPathComponent("contentblocker.json") }

    public func cachedListURL(sourceID: String) -> URL {
        listsCacheDirectory.appendingPathComponent("\(sourceID).txt")
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: listsCacheDirectory,
                                                withIntermediateDirectories: true)
    }

    /// A compiled blob that exists on disk but could not be loaded (for
    /// example because data protection hides it before first unlock).
    public struct BlobLoadFailure: Sendable {
        public let fileName: String
        public let error: String
    }

    private func loadBlob(_ url: URL, failures: inout [BlobLoadFailure]) -> CompiledBlocklistView? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try CompiledBlocklistView(contentsOf: url)
        } catch {
            failures.append(BlobLoadFailure(fileName: url.lastPathComponent, error: String(describing: error)))
            return nil
        }
    }

    /// Like `loadMatcher`, but also reports every blob that exists yet failed
    /// to load. Missing files are not failures.
    public func loadMatcherReportingFailures(
        builtInBlockHashes: Set<UInt64> = []
    ) -> (matcher: DomainMatcher, failures: [BlobLoadFailure]) {
        var failures: [BlobLoadFailure] = []
        let matcher = DomainMatcher(
            blocklist: loadBlob(blocklistURL, failures: &failures),
            userAllowlist: loadBlob(userAllowlistURL, failures: &failures),
            userDenylist: loadBlob(userDenylistURL, failures: &failures),
            builtInBlockHashes: builtInBlockHashes
        )
        return (matcher, failures)
    }

    /// Loads the current matcher from disk; missing files yield an empty
    /// matcher rather than an error so the tunnel can start before the first
    /// list download completes. Pass `builtInBlockHashes` (the seed
    /// fallback) so blocking never depends solely on the on-disk blob.
    public func loadMatcher(builtInBlockHashes: Set<UInt64> = []) -> DomainMatcher {
        loadMatcherReportingFailures(builtInBlockHashes: builtInBlockHashes).matcher
    }

    #if canImport(Darwin)
    /// Removes data protection from existing compiled blobs so installs that
    /// wrote them protected are fixed without a recompile. Returns errors.
    @discardableResult
    public func relaxBlobProtection() -> [BlobLoadFailure] {
        var failures: [BlobLoadFailure] = []
        for url in [blocklistURL, userAllowlistURL, userDenylistURL]
        where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                                      ofItemAtPath: url.path)
            } catch {
                failures.append(BlobLoadFailure(fileName: url.lastPathComponent, error: String(describing: error)))
            }
        }
        return failures
    }
    #endif
}
