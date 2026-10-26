import XCTest
@testable import IBlockerKit

final class IdentifierConstantsTests: XCTestCase {
    func testLogSubsystem() {
        XCTAssertEqual(Log.subsystem, "net.renalias.adblocker")
    }

    func testWidgetKinds() {
        XCTAssertEqual(WidgetKinds.statusWidget, "net.renalias.adblocker.widget.status")
        XCTAssertEqual(WidgetKinds.protectionControl, "net.renalias.adblocker.control.protection")
        XCTAssertEqual(WidgetKinds.pause5Control, "net.renalias.adblocker.control.pause5")
        XCTAssertEqual(WidgetKinds.pause10Control, "net.renalias.adblocker.control.pause10")
        XCTAssertEqual(WidgetKinds.pause30Control, "net.renalias.adblocker.control.pause30")
        XCTAssertEqual(WidgetKinds.pause60Control, "net.renalias.adblocker.control.pause60")
        let all = [WidgetKinds.statusWidget, WidgetKinds.protectionControl, WidgetKinds.pause5Control,
                   WidgetKinds.pause10Control, WidgetKinds.pause30Control, WidgetKinds.pause60Control]
        XCTAssertEqual(Set(all).count, all.count)
    }

    func testServerDescription() {
        XCTAssertEqual(TunnelConstants.serverDescription, "Personal AdBlocker (on-device)")
    }
}
