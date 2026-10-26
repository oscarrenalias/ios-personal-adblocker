import XCTest
@testable import IBlockerKit

final class WidgetEncryptionPresentationTests: XCTestCase {

    private func make(_ status: ResolverStatus?, active: Bool = true, paused: Bool = false)
        -> WidgetEncryptionPresentation {
        WidgetEncryptionPresentation(protectionActive: active, paused: paused, resolverStatus: status)
    }

    func testAlternativeEncrypted() {
        let p = make(.alternative(name: "Cloudflare", encrypted: true))
        XCTAssertEqual(p.state, .encrypted)
        XCTAssertEqual(p.symbol, "lock.fill")
        XCTAssertEqual(p.text, "Encrypted · Cloudflare")
        XCTAssertEqual(p.tone, .positive)
    }

    func testAlternativeUnencrypted() {
        let p = make(.alternative(name: "Quad9", encrypted: false))
        XCTAssertEqual(p.state, .unencrypted)
        XCTAssertEqual(p.symbol, "lock.open.fill")
        XCTAssertEqual(p.text, "Unencrypted · Quad9")
        XCTAssertEqual(p.tone, .warning)
    }

    func testNetwork() {
        let p = make(.network)
        XCTAssertEqual(p.state, .unencrypted)
        XCTAssertEqual(p.symbol, "lock.open.fill")
        XCTAssertEqual(p.text, "Unencrypted DNS")
        XCTAssertEqual(p.tone, .warning)
    }

    func testFallingBack() {
        let p = make(.fallingBack(name: "X"))
        XCTAssertEqual(p.state, .fallback)
        XCTAssertEqual(p.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(p.text, "Encrypted DNS unavailable")
        XCTAssertEqual(p.tone, .warning)
    }

    func testFailing() {
        let p = make(.failing(name: "X"))
        XCTAssertEqual(p.state, .failing)
        XCTAssertEqual(p.symbol, "xmark.octagon.fill")
        XCTAssertEqual(p.text, "DNS failing")
        XCTAssertEqual(p.tone, .critical)
    }

    func testActiveWithNilStatusIsUnknown() {
        let p = make(nil)
        XCTAssertEqual(p.state, .unknown)
        XCTAssertNil(p.symbol)
        XCTAssertNil(p.text)
        XCTAssertNil(p.tone)
    }

    func testOffAndPausedAreHiddenRegardlessOfStatus() {
        let statuses: [ResolverStatus?] = [
            nil, .network, .alternative(name: "A", encrypted: true),
            .alternative(name: "A", encrypted: false), .fallingBack(name: "A"), .failing(name: "A"),
        ]
        for status in statuses {
            for (active, paused) in [(false, false), (true, true), (false, true)] {
                let p = make(status, active: active, paused: paused)
                XCTAssertEqual(p.state, .hidden)
                XCTAssertNil(p.symbol)
                XCTAssertNil(p.text)
                XCTAssertNil(p.tone)
            }
        }
    }

    func testLogNames() {
        XCTAssertEqual(WidgetEncryptionPresentation.State.hidden.logName, "hidden")
        XCTAssertEqual(WidgetEncryptionPresentation.State.encrypted.logName, "encrypted")
        XCTAssertEqual(WidgetEncryptionPresentation.State.unencrypted.logName, "unencrypted")
        XCTAssertEqual(WidgetEncryptionPresentation.State.fallback.logName, "fallback")
        XCTAssertEqual(WidgetEncryptionPresentation.State.failing.logName, "failing")
        XCTAssertEqual(WidgetEncryptionPresentation.State.unknown.logName, "unknown")
    }
}
