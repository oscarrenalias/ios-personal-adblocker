import XCTest
@testable import IBlockerKit

final class IdentifierConstantsTests: XCTestCase {
    func testLogSubsystem() {
        XCTAssertEqual(Log.subsystem, "net.renalias.adblocker")
    }

    func testWidgetKinds() {
        XCTAssertEqual(WidgetKinds.statusWidget, "net.renalias.adblocker.widget.status")
        XCTAssertEqual(WidgetKinds.protectionControl, "net.renalias.adblocker.control.protection")
    }

    func testServerDescription() {
        XCTAssertEqual(TunnelConstants.serverDescription, "Personal AdBlocker (on-device)")
    }
}
