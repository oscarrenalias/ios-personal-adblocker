#if canImport(os)
import os
import XCTest
@testable import IBlockerKit

final class LogTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func text(_ counter: Counter) -> String {
        counter.value += 1
        return "built"
    }

    func testMessagesNotEvaluatedWhenLevelDisabled() {
        let counter = Counter()
        let log = Log(category: "test") { _ in false }
        log.debug(text(counter))
        log.info(text(counter))
        log.notice(text(counter))
        log.error(text(counter))
        XCTAssertEqual(counter.value, 0)
    }

    func testMessagesEvaluatedWhenLevelEnabled() {
        let counter = Counter()
        let log = Log(category: "test") { _ in true }
        log.debug(text(counter))
        log.info(text(counter))
        log.notice(text(counter))
        log.error(text(counter))
        XCTAssertEqual(counter.value, 4)
    }

    func testVerboseDebugEvaluatedWhenDebugDisabledButInfoEnabled() {
        Log.setVerbose(true)
        defer { Log.setVerbose(false) }
        let counter = Counter()
        let log = Log(category: "test") { $0 != .debug }
        log.debug(text(counter))
        XCTAssertEqual(counter.value, 1)
    }

    func testVerboseOffDebugNotEvaluatedWhenDebugDisabled() {
        Log.setVerbose(false)
        let counter = Counter()
        let log = Log(category: "test") { $0 != .debug }
        log.debug(text(counter))
        XCTAssertEqual(counter.value, 0)
    }

    func testOnlyMatchingLevelIsGated() {
        let counter = Counter()
        let log = Log(category: "test") { $0 != .debug }
        log.debug(text(counter))
        XCTAssertEqual(counter.value, 0)
        log.error(text(counter))
        XCTAssertEqual(counter.value, 1)
    }
}
#endif
