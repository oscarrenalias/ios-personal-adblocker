import XCTest
@testable import IBlockerKit

final class NotificationSettingsTests: XCTestCase {
    private func make() -> (SharedSettings, UserDefaults, String) {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SharedSettings(defaults: defaults), defaults, suite)
    }

    func testDefaults() {
        let (s, _, suite) = make()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertFalse(s.notificationsEnabled)
        for t in NotificationType.allCases { XCTAssertTrue(s.isNotificationTypeEnabled(t)) }
        XCTAssertFalse(s.userTurnedOff)
        XCTAssertEqual(s.notificationEpisode(forKind: "degraded"), NotificationEpisodeState())
        XCTAssertEqual(s.notificationFireTimes(forKind: "degraded"), [])
    }

    func testMasterAndTypeTogglesRoundTripIndependently() {
        let (s, _, suite) = make()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        s.notificationsEnabled = true
        XCTAssertTrue(s.notificationsEnabled)
        s.setNotificationType(.pause, enabled: false)
        XCTAssertFalse(s.isNotificationTypeEnabled(.pause))
        for t in [NotificationType.dns, .stopped, .lists] { XCTAssertTrue(s.isNotificationTypeEnabled(t)) }
        s.setNotificationType(.pause, enabled: true)
        XCTAssertTrue(s.isNotificationTypeEnabled(.pause))
        s.notificationsEnabled = false
        XCTAssertFalse(s.notificationsEnabled)
    }

    func testUserTurnedOffIndependentOfProtectionActive() {
        let (s, _, suite) = make()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        s.userTurnedOff = true
        s.protectionActive = false
        XCTAssertTrue(s.userTurnedOff)
        s.protectionActive = true
        XCTAssertTrue(s.userTurnedOff)
        s.userTurnedOff = false
        XCTAssertTrue(s.protectionActive)
    }

    func testEpisodeAndFireTimesRoundTripPerKind() {
        let (s, _, suite) = make()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let when = Date(timeIntervalSince1970: 1_700_000_000.5)
        let ep = NotificationEpisodeState(isOpen: true, scheduledFireTime: when, notified: true)
        s.setNotificationEpisode(ep, forKind: "resolver-fallback")
        s.setNotificationFireTimes([when, when.addingTimeInterval(60)], forKind: "resolver-fallback")
        XCTAssertEqual(s.notificationEpisode(forKind: "resolver-fallback"), ep)
        XCTAssertEqual(s.notificationFireTimes(forKind: "resolver-fallback"), [when, when.addingTimeInterval(60)])
        // Other kinds untouched.
        XCTAssertEqual(s.notificationEpisode(forKind: "resolver-failing"), NotificationEpisodeState())
        XCTAssertEqual(s.notificationFireTimes(forKind: "resolver-failing"), [])
        // Writing another kind keeps the first.
        s.setNotificationEpisode(.init(isOpen: true), forKind: "degraded")
        XCTAssertEqual(s.notificationEpisode(forKind: "resolver-fallback"), ep)
        XCTAssertTrue(s.notificationEpisode(forKind: "degraded").isOpen)
    }

    func testCorruptDataDecodesToEmpty() {
        let (s, defaults, suite) = make()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "notificationEpisodes")
        defaults.set(Data("{{".utf8), forKey: "notificationFireTimes")
        XCTAssertEqual(s.notificationEpisode(forKind: "degraded"), NotificationEpisodeState())
        XCTAssertEqual(s.notificationFireTimes(forKind: "degraded"), [])
        // Can still write after corruption.
        s.setNotificationEpisode(.init(isOpen: true), forKind: "degraded")
        XCTAssertTrue(s.notificationEpisode(forKind: "degraded").isOpen)
    }
}
