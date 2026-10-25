import XCTest
@testable import IBlockerKit

final class TunnelRecoveryTests: XCTestCase {

    func testRecoversSettingsThenBlocklistAndStopsRetrying() {
        var recovery = TunnelRecovery(settingsReadable: false, blocklistLoaded: false)
        XCTAssertTrue(recovery.isDegraded)

        for _ in 0..<3 {
            XCTAssertEqual(recovery.tick(settingsReadable: false, blocklistReadable: false), .init())
            XCTAssertTrue(recovery.isDegraded)
        }

        XCTAssertEqual(recovery.tick(settingsReadable: true, blocklistReadable: false),
                       .init(reapplySettings: true))
        XCTAssertTrue(recovery.isDegraded)

        XCTAssertEqual(recovery.tick(settingsReadable: true, blocklistReadable: false), .init())
        XCTAssertEqual(recovery.tick(settingsReadable: true, blocklistReadable: true),
                       .init(reloadMatcher: true))
        XCTAssertFalse(recovery.isDegraded)

        XCTAssertEqual(recovery.tick(settingsReadable: true, blocklistReadable: true), .init())
    }

    func testHealthyStartIsNotDegraded() {
        let recovery = TunnelRecovery(settingsReadable: true, blocklistLoaded: true)
        XCTAssertFalse(recovery.isDegraded)
    }

    func testBothRecoverTogether() {
        var recovery = TunnelRecovery(settingsReadable: false, blocklistLoaded: false)
        XCTAssertEqual(recovery.tick(settingsReadable: true, blocklistReadable: true),
                       .init(reapplySettings: true, reloadMatcher: true))
        XCTAssertFalse(recovery.isDegraded)
    }

    func testErrorLimiterOncePerDistinctErrorPerInterval() {
        var limiter = ErrorLogLimiter(interval: 60)
        let t0 = Date()
        XCTAssertTrue(limiter.shouldLog("a", now: t0))
        XCTAssertFalse(limiter.shouldLog("a", now: t0.addingTimeInterval(59)))
        XCTAssertTrue(limiter.shouldLog("b", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(limiter.shouldLog("a", now: t0.addingTimeInterval(61)))
    }

    func testBlobWriteOptions() throws {
        let options = CompiledBlocklist.writingOptions
        XCTAssertTrue(options.contains(.atomic))
        XCTAssertTrue(options.contains(.noFileProtection))
    }

    func testSettingsSentinelDefaultsUnsetAndRoundTrips() {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(settings.settingsAvailable)
        settings.settingsAvailable = true
        XCTAssertTrue(settings.settingsAvailable)
    }

    func testLoadMatcherReportsUnreadableBlobButNotMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppGroupPaths(containerURL: dir)
        XCTAssertTrue(paths.loadMatcherReportingFailures().failures.isEmpty)
        try Data([1, 2, 3]).write(to: paths.blocklistURL)
        let failures = paths.loadMatcherReportingFailures().failures
        XCTAssertEqual(failures.map(\.fileName), ["blocklist.bin"])
    }
}
