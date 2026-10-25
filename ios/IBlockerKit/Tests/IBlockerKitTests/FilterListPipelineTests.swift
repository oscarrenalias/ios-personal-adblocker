import XCTest
@testable import IBlockerKit

/// Updater accept/reject behaviour, metadata migration and FilterListStore.
final class FilterListPipelineTests: XCTestCase {

    private let url = URL(string: "https://lists.example.com/test.txt")!

    private func makeState() -> FilterListState {
        var state = FilterListState()
        state.sources = [FilterListSource(id: "test", name: "Test", url: url, enabled: true, isBuiltIn: false)]
        return state
    }

    private func body(_ n: Int, prefix: String = "d") -> Data {
        Data((0..<n).map { "0.0.0.0 \(prefix)\($0).example.com" }.joined(separator: "\n").utf8)
    }

    private func tempFiles(_ paths: AppGroupPaths) -> [String] {
        let dir = paths.cachedListURL(sourceID: "test").deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".download-") }
    }

    // MARK: Metadata

    func testMetadataRoundTripAllFields() throws {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let m = FilterListMetadata(etag: "e", lastModified: "lm", lastFetched: d, entryCount: 4, lastError: "x",
                                   lastChecked: d.addingTimeInterval(10), lastAccepted: d.addingTimeInterval(5),
                                   lastRejection: "nope")
        let decoded = try JSONDecoder().decode(FilterListMetadata.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(decoded, m)
    }

    func testMetadataMigratesLastAcceptedFromLastFetched() throws {
        let json = Data(#"{"lastFetched": 1000, "entryCount": 3}"#.utf8)
        let m = try JSONDecoder().decode(FilterListMetadata.self, from: json)
        XCTAssertNotNil(m.lastFetched)
        XCTAssertEqual(m.lastAccepted, m.lastFetched)
        XCTAssertNil(m.lastChecked)
        XCTAssertNil(m.lastRejection)
    }

    func testMetadataKeepsExplicitLastAccepted() throws {
        let json = Data(#"{"lastFetched": 1000, "lastAccepted": 500}"#.utf8)
        let m = try JSONDecoder().decode(FilterListMetadata.self, from: json)
        XCTAssertEqual(m.lastAccepted, Date(timeIntervalSinceReferenceDate: 500))
        XCTAssertNotEqual(m.lastAccepted, m.lastFetched)
    }

    // MARK: Updater

    func testFirstDownloadWithNoCachedFile() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        var state = makeState()
        let data = body(5)
        let updater = FilterListUpdater(paths: paths) { _ in FetchResult(statusCode: 200, body: data) }
        let summary = await updater.update(state: &state)
        XCTAssertEqual(summary.updatedSourceIDs, ["test"])
        XCTAssertEqual(try Data(contentsOf: paths.cachedListURL(sourceID: "test")), data)
        XCTAssertEqual(state.metadata["test"]?.entryCount, 5)
        XCTAssertTrue(tempFiles(paths).isEmpty)
    }

    func testAcceptedReplacesFileAndClearsRejection() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        var state = makeState()
        state.metadata["test"] = FilterListMetadata(entryCount: 5, lastError: "old", lastRejection: "old rejection")
        try paths.ensureDirectories()
        try Data("old".utf8).write(to: paths.cachedListURL(sourceID: "test"))

        let data = body(6)
        let updater = FilterListUpdater(paths: paths) { _ in FetchResult(statusCode: 200, body: data) }
        let summary = await updater.update(state: &state, force: true)

        XCTAssertEqual(summary.updatedSourceIDs, ["test"])
        XCTAssertEqual(try Data(contentsOf: paths.cachedListURL(sourceID: "test")), data)
        let m = try XCTUnwrap(state.metadata["test"])
        XCTAssertNil(m.lastRejection)
        XCTAssertNil(m.lastError)
        XCTAssertNotNil(m.lastAccepted)
        XCTAssertNotNil(m.lastChecked)
        XCTAssertEqual(m.entryCount, 6)
        XCTAssertTrue(tempFiles(paths).isEmpty)
    }

    private func assertRejected(_ rejectedBody: Data, previousCount: Int,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        var state = makeState()
        let accepted = Date(timeIntervalSince1970: 1_000_000)
        state.metadata["test"] = FilterListMetadata(etag: "old", lastFetched: accepted, entryCount: previousCount,
                                                    lastAccepted: accepted)
        try paths.ensureDirectories()
        let original = body(previousCount, prefix: "orig")
        try original.write(to: paths.cachedListURL(sourceID: "test"))

        let updater = FilterListUpdater(paths: paths) { _ in FetchResult(statusCode: 200, body: rejectedBody, etag: "new") }
        let summary = await updater.update(state: &state, force: true)

        XCTAssertEqual(summary.rejectedSourceIDs, ["test"], file: file, line: line)
        XCTAssertTrue(summary.updatedSourceIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(summary.failedSourceIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: paths.cachedListURL(sourceID: "test")), original, file: file, line: line)
        let m = try XCTUnwrap(state.metadata["test"], file: file, line: line)
        XCTAssertNotNil(m.lastRejection, file: file, line: line)
        XCTAssertNotNil(m.lastChecked, file: file, line: line)
        XCTAssertEqual(m.lastAccepted, accepted, file: file, line: line)
        XCTAssertEqual(m.etag, "old", file: file, line: line)
        XCTAssertEqual(m.entryCount, previousCount, file: file, line: line)
        XCTAssertTrue(tempFiles(paths).isEmpty, file: file, line: line)
    }

    func testRejectedHTMLKeepsCachedFile() async throws {
        try await assertRejected(Data("<!DOCTYPE html><html>Access denied</html>".utf8), previousCount: 10)
    }

    func testRejectedTinyListKeepsCachedFile() async throws {
        try await assertRejected(body(2), previousCount: 100)
    }

    func test304SetsLastCheckedAndClearsRejection() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        var state = makeState()
        state.metadata["test"] = FilterListMetadata(etag: "v1", entryCount: 3, lastRejection: "bad")
        try paths.ensureDirectories()
        try body(3).write(to: paths.cachedListURL(sourceID: "test"))
        let updater = FilterListUpdater(paths: paths) { _ in FetchResult(statusCode: 304, body: Data()) }
        let summary = await updater.update(state: &state)
        XCTAssertEqual(summary.unchangedSourceIDs, ["test"])
        XCTAssertNotNil(state.metadata["test"]?.lastChecked)
        XCTAssertNil(state.metadata["test"]?.lastRejection)
    }

    func testHTTPAndNetworkErrorsKeepCachedFile() async throws {
        for failure in [0, 1] {
            let paths = AppGroupPaths(containerURL: try makeTempDirectory())
            var state = makeState()
            try paths.ensureDirectories()
            let original = body(3)
            try original.write(to: paths.cachedListURL(sourceID: "test"))
            let updater = FilterListUpdater(paths: paths) { _ in
                if failure == 0 { return FetchResult(statusCode: 500, body: Data()) }
                throw URLError(.notConnectedToInternet)
            }
            let summary = await updater.update(state: &state, force: true)
            XCTAssertNotNil(summary.failedSourceIDs["test"])
            XCTAssertNotNil(state.metadata["test"]?.lastError)
            XCTAssertNotNil(state.metadata["test"]?.lastChecked)
            XCTAssertEqual(try Data(contentsOf: paths.cachedListURL(sourceID: "test")), original)
            XCTAssertTrue(tempFiles(paths).isEmpty)
        }
    }

    func testEmptyBodyIsError() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        var state = makeState()
        let updater = FilterListUpdater(paths: paths) { _ in FetchResult(statusCode: 200, body: Data()) }
        let summary = await updater.update(state: &state)
        XCTAssertEqual(summary.failedSourceIDs["test"], "Server returned an empty file")
        XCTAssertTrue(summary.rejectedSourceIDs.isEmpty)
    }

    // MARK: Store

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeStore(paths: AppGroupPaths, compiler: FilterListStore.Compiler? = nil,
                           fetch: @escaping FilterListUpdater.Fetch) async throws -> FilterListStore {
        try paths.ensureDirectories()
        let store: FilterListStore
        if let compiler {
            store = FilterListStore(paths: paths, compiler: compiler, fetch: fetch)
        } else {
            store = FilterListStore(paths: paths, fetch: fetch)
        }
        let source = FilterListSource(id: "test", name: "Test", url: url, enabled: true, isBuiltIn: false)
        try await store.mutate { state in
            for i in state.sources.indices { state.sources[i].enabled = false }
            state.sources.append(source)
        }
        return store
    }

    func testMutateConcurrentIncrementsAllLand() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        let store = try await makeStore(paths: paths) { _ in FetchResult(statusCode: 500, body: Data()) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { try? await store.mutate { $0.generation += 1 } }
            }
        }
        let generation = FilterListState.load(from: paths.filterStateURL).generation
        XCTAssertEqual(generation, 100)
    }

    func testMutateThrowingLeavesFileUnchanged() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        let store = try await makeStore(paths: paths) { _ in FetchResult(statusCode: 500, body: Data()) }
        let before = try Data(contentsOf: paths.filterStateURL)
        struct Boom: Error {}
        do {
            try await store.mutate { state in
                state.generation = 99
                throw Boom()
            }
            XCTFail("expected throw")
        } catch is Boom {}
        XCTAssertEqual(try Data(contentsOf: paths.filterStateURL), before)
    }

    func testCompileWithStubPersistsStateAndReturnsStats() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        let store = try await makeStore(paths: paths, compiler: { state, _ in
            state.generation = 42
            var stats = CompileStats()
            stats.blockedEntryCount = 7
            stats.generation = 42
            return stats
        }, fetch: { _ in FetchResult(statusCode: 500, body: Data()) })
        let stats = try await store.compile()
        XCTAssertEqual(stats.blockedEntryCount, 7)
        XCTAssertEqual(FilterListState.load(from: paths.filterStateURL).generation, 42)
    }

    func testCompileThrowingPropagatesAndDoesNotSave() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        struct Boom: Error {}
        let store = try await makeStore(paths: paths, compiler: { state, _ in
            state.generation = 42
            throw Boom()
        }, fetch: { _ in FetchResult(statusCode: 500, body: Data()) })
        do {
            _ = try await store.compile()
            XCTFail("expected throw")
        } catch is Boom {}
        XCTAssertEqual(FilterListState.load(from: paths.filterStateURL).generation, 0)
    }

    func testRealCompileInTempDir() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        let store = try await makeStore(paths: paths) { _ in FetchResult(statusCode: 500, body: Data()) }
        let stats = try await store.compile()
        XCTAssertGreaterThan(stats.generation, 0)
    }

    func testConcurrentUpdateAllJoinsAndFetchesOnce() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        let calls = Counter()
        let data = body(5)
        let store = try await makeStore(paths: paths) { _ in
            calls.increment()
            try await Task.sleep(nanoseconds: 300_000_000)
            return FetchResult(statusCode: 200, body: data)
        }
        async let a = store.updateAll(force: true, trigger: .user)
        async let b = store.updateAll(force: true, trigger: .shortcut)
        let (s1, s2) = await (a, b)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(s1, s2)
        XCTAssertEqual(s1.updatedSourceIDs, ["test"])

        // Metadata persisted and compile ran (generation bumped).
        let state = FilterListState.load(from: paths.filterStateURL)
        XCTAssertEqual(state.metadata["test"]?.entryCount, 5)
        XCTAssertNotNil(state.metadata["test"]?.lastAccepted)
        XCTAssertGreaterThan(state.generation, 0)

        // A later sequential call runs again.
        _ = await store.updateAll(force: true, trigger: .user)
        XCTAssertEqual(calls.value, 2)
    }

    func testConcurrentMixedUpdatesAllComplete() async throws {
        for _ in 0..<5 {
            let paths = AppGroupPaths(containerURL: try makeTempDirectory())
            let data = body(5)
            let store = try await makeStore(paths: paths) { _ in
                try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...10_000_000))
                return FetchResult(statusCode: 200, body: data)
            }
            let finished = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withTaskGroup(of: Void.self) { inner in
                        for i in 0..<50 {
                            inner.addTask {
                                if i % 2 == 0 {
                                    _ = await store.updateAll(force: true, trigger: .user)
                                } else {
                                    _ = await store.update(sourceIDs: ["test"], force: true, trigger: .user)
                                }
                            }
                        }
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            XCTAssertTrue(finished, "mixed concurrent updates did not complete within 10 s")
            if !finished { return }
        }
    }

    func testUpdateAllSummaryCountsAndCompileOnlyWhenChanged() async throws {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        let mode = Counter()
        let compiles = Counter()
        let good = body(5)
        let store = try await makeStore(paths: paths, compiler: { state, _ in
            compiles.increment()
            return CompileStats()
        }, fetch: { _ in
            switch mode.value {
            case 0: return FetchResult(statusCode: 304, body: Data())
            case 1: return FetchResult(statusCode: 200, body: Data("<html></html>".utf8))
            case 2: return FetchResult(statusCode: 503, body: Data())
            case 3: throw URLError(.timedOut)
            default: return FetchResult(statusCode: 200, body: good)
            }
        })

        var s = await store.updateAll(force: true, trigger: .user)
        XCTAssertEqual(s.unchangedSourceIDs, ["test"])
        mode.increment()
        s = await store.updateAll(force: true, trigger: .user)
        XCTAssertEqual(s.rejectedSourceIDs, ["test"])
        mode.increment()
        s = await store.updateAll(force: true, trigger: .user)
        XCTAssertNotNil(s.failedSourceIDs["test"])
        mode.increment()
        s = await store.updateAll(force: true, trigger: .user)
        XCTAssertNotNil(s.failedSourceIDs["test"])
        XCTAssertEqual(compiles.value, 0)

        mode.increment()
        s = await store.updateAll(force: true, trigger: .user)
        XCTAssertEqual(s.updatedSourceIDs, ["test"])
        XCTAssertEqual(compiles.value, 1)
        XCTAssertEqual(FilterListState.load(from: paths.filterStateURL).metadata["test"]?.entryCount, 5)
    }

    // MARK: Targeted update (add custom list)

    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func add(_ u: String) { lock.lock(); urls.append(u); lock.unlock() }
        var value: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private func runTargeted(_ respond: @escaping @Sendable (URLRequest) throws -> FetchResult)
        async throws -> (UpdateSummary, [String]) {
        let paths = AppGroupPaths(containerURL: try makeTempDirectory())
        try paths.ensureDirectories()
        let seen = URLRecorder()
        let store = FilterListStore(paths: paths) { request in
            seen.add(request.url?.absoluteString ?? "?")
            return try respond(request)
        }
        let other = URL(string: "https://other.example.com/o.txt")!
        try await store.mutate { state in
            for i in state.sources.indices { state.sources[i].enabled = false }
            state.sources.append(FilterListSource(id: "old", name: "Old", url: other, enabled: true, isBuiltIn: false))
            state.sources.append(FilterListSource(id: "new", name: "New", url: self.url, enabled: true, isBuiltIn: false))
        }
        let summary = await store.update(sourceIDs: ["new"], trigger: .user)
        return (summary, seen.value)
    }

    func testTargetedUpdateReportsRejectionReasonForHTMLPage() async throws {
        let html = Data("<!DOCTYPE html><html><body>Example Domain</body></html>".utf8)
        let (summary, fetched) = try await runTargeted { _ in FetchResult(statusCode: 200, body: html) }
        XCTAssertEqual(summary.rejectedSourceIDs, ["new"])
        XCTAssertEqual(summary.rejectedReasons["new"], "Server returned a web page, not a list")
        XCTAssertEqual(fetched, [url.absoluteString])
    }

    func testTargetedUpdateReportsNetworkFailure() async throws {
        let (summary, fetched) = try await runTargeted { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(summary.failedSourceIDs["new"], "No internet connection")
        XCTAssertTrue(summary.rejectedReasons.isEmpty)
        XCTAssertEqual(fetched, [url.absoluteString])
    }

    func testTargetedUpdateAcceptsValidList() async throws {
        let data = body(5)
        let (summary, fetched) = try await runTargeted { _ in FetchResult(statusCode: 200, body: data) }
        XCTAssertEqual(summary.updatedSourceIDs, ["new"])
        XCTAssertEqual(fetched, [url.absoluteString])
    }
}
