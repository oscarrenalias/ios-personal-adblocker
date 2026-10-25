import XCTest
@testable import IBlockerKit

final class FilterListValidatorTests: XCTestCase {

    private func domains(_ n: Int, prefix: String = "d") -> String {
        (0..<n).map { "0.0.0.0 \(prefix)\($0).example.com" }.joined(separator: "\n")
    }

    private func assertReject(_ outcome: FilterListValidator.Outcome, _ reason: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome, .reject(reason: reason), file: file, line: line)
    }

    private let htmlReason = "Server returned a web page, not a list"

    func testHTMLVariantsRejected() {
        assertReject(FilterListValidator.validate("<!DOCTYPE html><html></html>", previousCount: nil), htmlReason)
        assertReject(FilterListValidator.validate("<html><body>blocked</body></html>", previousCount: nil), htmlReason)
        assertReject(FilterListValidator.validate("  \n\t<html>\n" + domains(5), previousCount: nil), htmlReason)
        assertReject(FilterListValidator.validate("\u{FEFF}<html>" + domains(5), previousCount: nil), htmlReason)
    }

    func testEmptyAndCommentsOnlyRejected() {
        let reason = "Download contained no rules"
        assertReject(FilterListValidator.validate("", previousCount: nil), reason)
        assertReject(FilterListValidator.validate("# a\n! b\n", previousCount: nil), reason)
    }

    func testSkippedFractionBoundary() {
        // 5 good + 5 unparseable = exactly 50% skipped -> accepted.
        let junk = (0..<5).map { _ in "this is not a rule" }.joined(separator: "\n")
        XCTAssertEqual(FilterListValidator.validate(domains(5) + "\n" + junk, previousCount: nil),
                       .accept(entryCount: 5))

        // 4 good + 6 unparseable = 60% skipped -> rejected.
        let junk6 = (0..<6).map { _ in "this is not a rule" }.joined(separator: "\n")
        let outcome = FilterListValidator.validate(domains(4) + "\n" + junk6, previousCount: nil)
        assertReject(outcome, "Most lines couldn't be read (6 of 10)")
    }

    func testShrinkBoundary() {
        XCTAssertEqual(FilterListValidator.validate(domains(60), previousCount: 100), .accept(entryCount: 60))
        XCTAssertEqual(FilterListValidator.validate(domains(50), previousCount: 100), .accept(entryCount: 50))
        assertReject(FilterListValidator.validate(domains(49), previousCount: 100),
                     "Has 49 rules, was 100 — kept the previous version")
    }

    func testNilAndZeroPreviousAccepted() {
        XCTAssertEqual(FilterListValidator.validate(domains(3), previousCount: nil), .accept(entryCount: 3))
        XCTAssertEqual(FilterListValidator.validate(domains(3), previousCount: 0), .accept(entryCount: 3))
    }

    func testRuleOrder() {
        // HTML beats empty.
        assertReject(FilterListValidator.validate("<html></html>", previousCount: 100), htmlReason)
        // Empty beats shrink.
        assertReject(FilterListValidator.validate("# only comments", previousCount: 100), "Download contained no rules")
        // Skipped beats shrink: 1 good + 9 junk against previous 100.
        let junk = (0..<9).map { _ in "this is not a rule" }.joined(separator: "\n")
        let outcome = FilterListValidator.validate(domains(1) + "\n" + junk, previousCount: 100)
        assertReject(outcome, "Most lines couldn't be read (9 of 10)")
    }
}
