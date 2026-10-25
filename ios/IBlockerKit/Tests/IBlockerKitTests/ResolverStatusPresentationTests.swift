import XCTest
@testable import IBlockerKit

final class ResolverStatusPresentationTests: XCTestCase {
    private func make(_ status: ResolverStatus?, connected: Bool = true) -> ResolverStatusPresentation {
        ResolverStatusPresentation(tunnelConnected: connected, resolverStatus: status)
    }

    func testNilStatusIsGenericProtected() {
        let p = make(nil)
        XCTAssertEqual(p.icon, "checkmark.shield.fill")
        XCTAssertEqual(p.tone, .positive)
        XCTAssertEqual(p.mainLine, "Protected — DNS filtering active")
        XCTAssertNil(p.caption)
        XCTAssertFalse(p.showsDNSSettingsButton)
    }

    func testNetworkIsUnencryptedWarning() {
        let p = make(.network)
        XCTAssertEqual(p.icon, "lock.open.fill")
        XCTAssertEqual(p.tone, .warning)
        XCTAssertEqual(p.mainLine, "Protected — unencrypted DNS (Network DNS)")
        XCTAssertEqual(p.caption, "Your network can see the sites you look up.")
        XCTAssertFalse(p.showsDNSSettingsButton)
    }

    func testAlternativeEncryptedIsPositive() {
        let p = make(.alternative(name: "Quad9", encrypted: true))
        XCTAssertEqual(p.icon, "checkmark.shield.fill")
        XCTAssertEqual(p.tone, .positive)
        XCTAssertEqual(p.mainLine, "Protected — encrypted DNS (Quad9)")
        XCTAssertNil(p.caption)
        XCTAssertFalse(p.showsDNSSettingsButton)
    }

    func testAlternativeUnencryptedInterpolatesNameTwice() {
        let p = make(.alternative(name: "Custom", encrypted: false))
        XCTAssertEqual(p.icon, "lock.open.fill")
        XCTAssertEqual(p.tone, .warning)
        XCTAssertEqual(p.mainLine, "Protected — unencrypted DNS (Custom)")
        XCTAssertEqual(p.caption, "Custom and your network can see the sites you look up.")
        XCTAssertFalse(p.showsDNSSettingsButton)
    }

    func testFallingBackShowsButton() {
        let p = make(.fallingBack(name: "Quad9"))
        XCTAssertEqual(p.icon, "exclamationmark.triangle.fill")
        XCTAssertEqual(p.tone, .warning)
        XCTAssertEqual(p.mainLine, "Protected — encrypted DNS unavailable")
        XCTAssertEqual(p.caption,
                       "Quad9 can't be reached. Lookups are going unencrypted to your network's DNS until it's back.")
        XCTAssertTrue(p.showsDNSSettingsButton)
    }

    func testFailingIsCriticalWithButton() {
        let p = make(.failing(name: "Quad9"))
        XCTAssertEqual(p.icon, "xmark.octagon.fill")
        XCTAssertEqual(p.tone, .critical)
        XCTAssertEqual(p.mainLine, "DNS lookups are failing")
        XCTAssertEqual(p.caption, "Quad9 can't be reached and fallback is off.")
        XCTAssertTrue(p.showsDNSSettingsButton)
    }

    func testDisconnectedIsNeutralForEveryStatus() {
        let statuses: [ResolverStatus?] = [
            nil, .network, .alternative(name: "A", encrypted: true), .alternative(name: "A", encrypted: false),
            .fallingBack(name: "A"), .failing(name: "A"),
        ]
        for s in statuses {
            let p = make(s, connected: false)
            XCTAssertEqual(p.tone, .neutral)
            XCTAssertEqual(p.mainLine, "")
            XCTAssertNil(p.caption)
            XCTAssertFalse(p.showsDNSSettingsButton)
        }
    }
}
