import XCTest
@testable import IBlockerKit

final class NotificationPolicyTests: XCTestCase {
    private typealias Kind = StatusNotificationKind
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let on = StatusNotificationPreferences(masterEnabled: true)

    private func decide(
        _ event: StatusNotificationEvent,
        _ state: StatusNotificationState = .init(),
        prefs: StatusNotificationPreferences? = nil,
        at now: Date? = nil
    ) -> StatusNotificationDecision {
        StatusNotificationPolicy.decide(event: event, state: state, preferences: prefs ?? on, now: now ?? t0)
    }

    // MARK: Kinds and stop classification

    func testDebounceTabAndPreferenceMapping() {
        XCTAssertEqual(Kind.resolverFallback.debounceDelay, 30)
        XCTAssertEqual(Kind.resolverFailing.debounceDelay, 30)
        XCTAssertEqual(Kind.protectionStopped.debounceDelay, 60)
        XCTAssertEqual(Kind.degraded.debounceDelay, 300)
        for k in [Kind.restored, .listRejected, .listStale, .pauseEnded] { XCTAssertEqual(k.debounceDelay, 0) }
        for k in Kind.allCases {
            XCTAssertEqual(k.targetTab, (k == .listRejected || k == .listStale) ? .lists : .dashboard)
        }
        XCTAssertEqual(Kind.resolverFallback.preferenceType, .encryptedDNS)
        XCTAssertEqual(Kind.resolverFailing.preferenceType, .encryptedDNS)
        XCTAssertEqual(Kind.protectionStopped.preferenceType, .protectionStopped)
        XCTAssertEqual(Kind.degraded.preferenceType, .protectionStopped)
        XCTAssertEqual(Kind.pauseEnded.preferenceType, .pauseEnded)
        XCTAssertEqual(Kind.listRejected.preferenceType, .blocklists)
        XCTAssertEqual(Kind.listStale.preferenceType, .blocklists)
        XCTAssertNil(Kind.restored.preferenceType)
    }

    func testStopReasonRawValues() {
        XCTAssertEqual(TunnelStopReason(rawValue: 0), .none)
        XCTAssertEqual(TunnelStopReason(rawValue: 1), .userInitiated)
        XCTAssertEqual(TunnelStopReason(rawValue: 2), .providerFailed)
        XCTAssertEqual(TunnelStopReason(rawValue: 11), .superceded)
        XCTAssertEqual(TunnelStopReason(rawValue: 15), .sleep)
        XCTAssertEqual(TunnelStopReason(rawValue: 16), .appUpdate)
        XCTAssertEqual(TunnelStopReason(rawValue: 99), .other(99))
        XCTAssertEqual(TunnelStopReason(rawValue: -1), .other(-1))
        for raw in 0...16 {
            if case .other = TunnelStopReason(rawValue: raw) { XCTFail("raw \(raw) unmapped") }
        }
    }

    func testClassifyStop() {
        let c = StatusNotificationPolicy.classifyStop
        for raw in 0...17 {
            XCTAssertEqual(c(TunnelStopReason(rawValue: raw), true), .expected)
        }
        XCTAssertEqual(c(.userInitiated, false), .expected)
        XCTAssertEqual(c(.appUpdate, false), .expected)
        for r: TunnelStopReason in [.superceded, .providerFailed, .other(42), .none, .sleep] {
            XCTAssertEqual(c(r, false), .unexpected, "\(r)")
        }
        XCTAssertTrue(StatusNotificationPolicy.shouldNotifyStop(reason: .superceded, userTurnedOffMarker: false))
        XCTAssertFalse(StatusNotificationPolicy.shouldNotifyStop(reason: .superceded, userTurnedOffMarker: true))
    }

    // MARK: Policy

    func testProblemStartedSchedulesAfterDebounce() {
        for kind in [Kind.resolverFallback, .resolverFailing, .protectionStopped, .degraded] {
            let d = decide(.problemStarted(kind))
            XCTAssertEqual(d.actions, [.schedule(kind, fireDate: t0.addingTimeInterval(kind.debounceDelay))])
            XCTAssertTrue(d.state.episode(kind).isOpen)
        }
    }

    func testRepeatedProblemStartedSuppressedAsAlreadyNotified() {
        let first = decide(.problemStarted(.resolverFallback))
        let second = decide(.problemStarted(.resolverFallback), first.state, at: t0.addingTimeInterval(5))
        XCTAssertTrue(second.actions.isEmpty)
        XCTAssertEqual(second.suppressions.map(\.reason), [.alreadyNotified])
        XCTAssertEqual(second.state.episode(.resolverFallback), first.state.episode(.resolverFallback))
    }

    func testRateLimitSuppressesButKeepsEpisodeOpenWithNoRestore() {
        var state = StatusNotificationState()
        state.fireTimes[.protectionStopped] = [t0.addingTimeInterval(-120)]
        let d = decide(.problemStarted(.protectionStopped), state)
        XCTAssertTrue(d.actions.isEmpty)
        XCTAssertEqual(d.suppressions.map(\.reason), [.rateLimited])
        XCTAssertTrue(d.state.episode(.protectionStopped).isOpen)
        XCTAssertNil(d.state.episode(.protectionStopped).scheduledFireTime)

        let cleared = decide(.problemCleared(.protectionStopped), d.state, at: t0.addingTimeInterval(600))
        XCTAssertTrue(cleared.actions.isEmpty)
        XCTAssertFalse(cleared.state.episode(.protectionStopped).isOpen)
    }

    func testRateLimitExpiresAfterFiveMinutes() {
        var state = StatusNotificationState()
        state.fireTimes[.protectionStopped] = [t0.addingTimeInterval(-400)]
        let d = decide(.problemStarted(.protectionStopped), state)
        XCTAssertEqual(d.actions.count, 1)
    }

    func testClearBeforeFireTimeCancelsWithoutRestore() {
        let start = decide(.problemStarted(.resolverFallback))
        let d = decide(.problemCleared(.resolverFallback), start.state, at: t0.addingTimeInterval(10))
        XCTAssertEqual(d.actions, [.cancel(.resolverFallback, clearedAfter: 10)])
        XCTAssertFalse(d.state.episode(.resolverFallback).isOpen)
        XCTAssertTrue(d.state.times(.resolverFallback).isEmpty)
    }

    func testClearAfterFireTimePostsRestoreWithoutRateLimit() {
        let start = decide(.problemStarted(.resolverFallback))
        let later = t0.addingTimeInterval(45)
        let d = decide(.problemCleared(.resolverFallback), start.state, at: later)
        XCTAssertEqual(d.actions, [.postRestore(forKind: .resolverFallback)])
        XCTAssertFalse(d.state.episode(.resolverFallback).isOpen)
        XCTAssertTrue(d.state.times(.restored).isEmpty)
    }

    func testRestoreOfOneKindDoesNotSuppressRestoreOfAnother() {
        let dns = decide(.problemStarted(.resolverFallback))
        let stopped = decide(.problemStarted(.protectionStopped), dns.state, at: t0.addingTimeInterval(1))
        let r1 = decide(.problemCleared(.resolverFallback), stopped.state, at: t0.addingTimeInterval(100))
        XCTAssertEqual(r1.actions, [.postRestore(forKind: .resolverFallback)])
        let r2 = decide(.problemCleared(.protectionStopped), r1.state, at: t0.addingTimeInterval(220))
        XCTAssertEqual(r2.actions, [.postRestore(forKind: .protectionStopped)])
        XCTAssertTrue(r2.suppressions.isEmpty)
    }

    func testDismissedPendingEpisodeCancelsWithoutRestore() {
        let start = decide(.problemStarted(.resolverFallback))
        let d = decide(.problemDismissed(.resolverFallback), start.state, at: t0.addingTimeInterval(10))
        XCTAssertEqual(d.actions, [.cancel(.resolverFallback, clearedAfter: 10)])
        XCTAssertFalse(d.state.episode(.resolverFallback).isOpen)
    }

    func testDismissedDeliveredEpisodeEndsWithoutRestore() {
        let start = decide(.problemStarted(.resolverFailing))
        let d = decide(.problemDismissed(.resolverFailing), start.state, at: t0.addingTimeInterval(60))
        XCTAssertTrue(d.actions.isEmpty)
        XCTAssertFalse(d.state.episode(.resolverFailing).isOpen)
    }

    func testClearWithoutOpenEpisodeIsNoOp() {
        let d = decide(.problemCleared(.resolverFallback))
        XCTAssertTrue(d.actions.isEmpty)
        XCTAssertEqual(d.state, StatusNotificationState())
    }

    func testKindChangeEndsOldSilentlyAndSchedulesNew() {
        let start = decide(.problemStarted(.resolverFallback))
        let now = t0.addingTimeInterval(5)
        let d = decide(.problemStarted(.resolverFailing), start.state, at: now)
        XCTAssertEqual(d.actions.count, 2)
        guard case .cancel(.resolverFallback, _) = d.actions[0] else { return XCTFail("\(d.actions)") }
        XCTAssertEqual(d.actions[1], .schedule(.resolverFailing, fireDate: now.addingTimeInterval(30)))
        XCTAssertFalse(d.state.episode(.resolverFallback).isOpen)
        XCTAssertTrue(d.state.episode(.resolverFailing).isOpen)
        XCTAssertFalse(d.actions.contains(.postRestore(forKind: .resolverFallback)))
    }

    func testTunnelStoppedCancelsPendingAndLeavesProtectionStoppedOpen() {
        var state = StatusNotificationState()
        let fire = t0.addingTimeInterval(100)
        for k in [Kind.resolverFallback, .resolverFailing, .pauseEnded, .degraded, .protectionStopped] {
            state.episodes[k] = .init(isOpen: true, scheduledFireTime: fire, notified: false)
            state.fireTimes[k] = [fire]
        }
        let d = decide(.tunnelStopped, state)
        let cancelled = Set(d.actions.compactMap { a -> Kind? in
            if case .cancel(let k, _) = a { return k } else { return nil }
        })
        XCTAssertEqual(cancelled, [.resolverFallback, .resolverFailing, .pauseEnded, .degraded])
        XCTAssertFalse(d.actions.contains { if case .postRestore = $0 { true } else { false } })
        for k in cancelled { XCTAssertFalse(d.state.episode(k).isOpen) }
        XCTAssertTrue(d.state.episode(.protectionStopped).isOpen)
    }

    func testProtectionStoppedSecondStopDoesNotRescheduleAndStartBeforeDeliveryCancels() {
        let first = decide(.problemStarted(.protectionStopped))
        XCTAssertEqual(first.actions, [.schedule(.protectionStopped, fireDate: t0.addingTimeInterval(60))])
        let second = decide(.problemStarted(.protectionStopped), first.state, at: t0.addingTimeInterval(20))
        XCTAssertTrue(second.actions.isEmpty)
        let start = decide(.problemCleared(.protectionStopped), second.state, at: t0.addingTimeInterval(30))
        XCTAssertEqual(start.actions.count, 1)
        guard case .cancel(.protectionStopped, _) = start.actions[0] else { return XCTFail() }
    }

    func testProtectionStoppedStartAfterDeliveryPostsRestore() {
        let first = decide(.problemStarted(.protectionStopped))
        let d = decide(.problemCleared(.protectionStopped), first.state, at: t0.addingTimeInterval(120))
        XCTAssertEqual(d.actions, [.postRestore(forKind: .protectionStopped)])
    }

    func testPauseDeadlineScheduleChangeClearAndPast() {
        let deadline = t0.addingTimeInterval(600)
        let s1 = decide(.pauseDeadline(deadline))
        XCTAssertEqual(s1.actions, [.schedule(.pauseEnded, fireDate: deadline)])

        let unchanged = decide(.pauseDeadline(deadline), s1.state, at: t0.addingTimeInterval(1))
        XCTAssertTrue(unchanged.actions.isEmpty)

        // Changed deadline: schedule again (same identifier replaces). Use >5min apart? Rate limit applies
        // only to other fire times; the old one is removed first.
        let newDeadline = deadline.addingTimeInterval(120)
        let changed = decide(.pauseDeadline(newDeadline), s1.state, at: t0.addingTimeInterval(1))
        XCTAssertEqual(changed.actions, [.schedule(.pauseEnded, fireDate: newDeadline)])
        XCTAssertEqual(changed.state.times(.pauseEnded), [newDeadline])

        let cleared = decide(.pauseDeadline(nil), s1.state, at: t0.addingTimeInterval(1))
        guard case .cancel(.pauseEnded, _) = cleared.actions.first else { return XCTFail("\(cleared.actions)") }
        XCTAssertFalse(cleared.state.episode(.pauseEnded).isOpen)

        let past = decide(.pauseDeadline(t0.addingTimeInterval(-5)), s1.state, at: t0.addingTimeInterval(1))
        guard case .cancel(.pauseEnded, _) = past.actions.first else { return XCTFail("\(past.actions)") }

        let none = decide(.pauseDeadline(t0.addingTimeInterval(-5)))
        XCTAssertTrue(none.actions.isEmpty)
    }

    func testPausePreferencesOffSuppress() {
        let d = decide(.pauseDeadline(t0.addingTimeInterval(60)),
                       prefs: .init(masterEnabled: true, disabledTypes: [.pauseEnded]))
        XCTAssertTrue(d.actions.isEmpty)
        XCTAssertEqual(d.suppressions.map(\.reason), [.typeDisabled])
    }

    func testMasterOffAndTypeDisabledSuppressProblems() {
        let master = decide(.problemStarted(.resolverFallback), prefs: .init(masterEnabled: false))
        XCTAssertTrue(master.actions.isEmpty)
        XCTAssertEqual(master.suppressions.map(\.reason), [.masterOff])
        XCTAssertFalse(master.state.episode(.resolverFallback).isOpen)

        let type = decide(.problemStarted(.resolverFallback),
                          prefs: .init(masterEnabled: true, disabledTypes: [.encryptedDNS]))
        XCTAssertEqual(type.suppressions.map(\.reason), [.typeDisabled])
        // Other types unaffected.
        let other = decide(.problemStarted(.protectionStopped),
                           prefs: .init(masterEnabled: true, disabledTypes: [.encryptedDNS]))
        XCTAssertEqual(other.actions.count, 1)
    }

    func testRestoreSuppressedWhenPreferencesTurnedOffAfterDelivery() {
        let start = decide(.problemStarted(.resolverFallback))
        let d = decide(.problemCleared(.resolverFallback), start.state,
                       prefs: .init(masterEnabled: false), at: t0.addingTimeInterval(60))
        XCTAssertTrue(d.actions.isEmpty)
        XCTAssertFalse(d.state.episode(.resolverFallback).isOpen)
    }

    func testOneShot() {
        let d = decide(.oneShot(.listRejected))
        XCTAssertEqual(d.actions, [.schedule(.listRejected, fireDate: t0)])
        XCTAssertFalse(d.state.episode(.listRejected).isOpen)

        let limited = decide(.oneShot(.listRejected), d.state, at: t0.addingTimeInterval(60))
        XCTAssertTrue(limited.actions.isEmpty)
        XCTAssertEqual(limited.suppressions.map(\.reason), [.rateLimited])

        let off = decide(.oneShot(.listStale), prefs: .init(masterEnabled: true, disabledTypes: [.blocklists]))
        XCTAssertTrue(off.actions.isEmpty)
    }

    func testPreferencesFromSettings() {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(StatusNotificationPreferences(settings: settings),
                       .init(masterEnabled: false, disabledTypes: []))
        settings.notificationsEnabled = true
        settings.setNotificationType(.dns, enabled: false)
        settings.setNotificationType(.lists, enabled: false)
        XCTAssertEqual(StatusNotificationPreferences(settings: settings),
                       .init(masterEnabled: true, disabledTypes: [.encryptedDNS, .blocklists]))
    }

    func testStateSaveLoadRoundTrip() {
        let suite = "iblocker-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = SharedSettings(defaults: UserDefaults(suiteName: suite)!)
        var state = StatusNotificationState()
        state.episodes[.degraded] = .init(isOpen: true, scheduledFireTime: t0, notified: true)
        state.fireTimes[.degraded] = [t0, t0.addingTimeInterval(9)]
        state.save(to: settings)
        let loaded = StatusNotificationState.load(from: settings)
        XCTAssertEqual(loaded.episode(.degraded), state.episode(.degraded))
        XCTAssertEqual(loaded.times(.degraded), state.times(.degraded))
        XCTAssertFalse(loaded.episode(.resolverFallback).isOpen)
    }

    // MARK: Content builders

    func testResolverDisplayNames() {
        let f = StatusNotificationContentBuilder.resolverDisplayName
        XCTAssertEqual(f("Quad9"), "Quad9")
        XCTAssertEqual(f("Custom"), "your custom resolver")
        XCTAssertEqual(f(""), "your custom resolver")
        XCTAssertEqual(f("https://dns.example.com/dns-query"), "your custom resolver")

        let custom = StatusNotificationContentBuilder.problem(.resolverFailing, resolverName: "dns.example.com")!
        XCTAssertTrue(custom.body.contains("your custom resolver"))
        XCTAssertFalse(custom.body.contains("example"))
        let empty = StatusNotificationContentBuilder.problem(.resolverFailing, resolverName: "")!
        XCTAssertTrue(empty.body.contains("your custom resolver"))
        let quad = StatusNotificationContentBuilder.problem(.resolverFailing, resolverName: "Quad9")!
        XCTAssertTrue(quad.body.contains("Quad9"))
        XCTAssertFalse(quad.body.contains("9.9.9.9"))
        let restore = StatusNotificationContentBuilder.restore(forKind: .resolverFallback, resolverName: "Quad9")!
        XCTAssertTrue(restore.body.contains("Quad9"))
    }

    func testListDisplayNames() {
        let url = URL(string: "https://lists.example.org/hosts.txt")!
        func src(_ name: String, builtIn: Bool = false) -> FilterListSource {
            FilterListSource(id: "x", name: name, url: url, enabled: true, isBuiltIn: builtIn)
        }
        XCTAssertEqual(StatusNotificationContentBuilder.listDisplayName(src("")), "a custom blocklist")
        XCTAssertEqual(StatusNotificationContentBuilder.listDisplayName(src("  \n")), "a custom blocklist")
        XCTAssertEqual(StatusNotificationContentBuilder.listDisplayName(src(" Mine ")), "Mine")
        XCTAssertEqual(StatusNotificationContentBuilder.listDisplayName(src("OISD", builtIn: true)), "OISD")
        let name = StatusNotificationContentBuilder.listDisplayName(src(""))
        let c = StatusNotificationContentBuilder.problem(.listRejected, listName: name)!
        XCTAssertTrue(c.body.contains("a custom blocklist"))
        XCTAssertFalse(c.body.contains("example.org"))
    }

    func testUserInfoTabsAndIdentifiers() {
        for kind in Kind.allCases {
            guard let c = StatusNotificationContentBuilder.problem(kind, resolverName: "Quad9", listName: "L") else {
                XCTAssertEqual(kind, .restored); continue
            }
            let tab = (kind == .listRejected || kind == .listStale) ? "lists" : "dashboard"
            XCTAssertEqual(c.userInfo[StatusNotificationContent.tabKey], tab, "\(kind)")
            XCTAssertEqual(c.userInfo[StatusNotificationContent.kindKey], kind.rawValue)
            XCTAssertEqual(c.identifier, "status.\(kind.rawValue)")
        }
        XCTAssertNil(StatusNotificationContentBuilder.problem(.restored))
    }

    func testRestoreContent() {
        for kind in [Kind.resolverFallback, .resolverFailing, .protectionStopped, .degraded] {
            let p = StatusNotificationContentBuilder.problem(kind, resolverName: "Quad9")!
            let r = StatusNotificationContentBuilder.restore(forKind: kind, resolverName: "Quad9")!
            XCTAssertEqual(r.identifier, p.identifier)
            XCTAssertEqual(r.userInfo[StatusNotificationContent.tabKey], "dashboard")
        }
        for kind in [Kind.listRejected, .listStale, .pauseEnded, .restored] {
            XCTAssertNil(StatusNotificationContentBuilder.restore(forKind: kind))
        }
    }

    func testNoContentContainsDomainIPOrURL() throws {
        let pattern = try NSRegularExpression(
            pattern: #"https?://|\b\d{1,3}(\.\d{1,3}){3}\b|\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|net|org|io|dev|invalid|local)\b"#,
            options: .caseInsensitive)
        var all: [StatusNotificationContent] = []
        for kind in Kind.allCases {
            if let c = StatusNotificationContentBuilder.problem(kind, resolverName: "https://9.9.9.9/dns-query") { all.append(c) }
            if let c = StatusNotificationContentBuilder.restore(forKind: kind, resolverName: "dns.example.com") { all.append(c) }
        }
        XCTAssertFalse(all.isEmpty)
        for c in all {
            for text in [c.title, c.body] {
                let range = NSRange(text.startIndex..., in: text)
                XCTAssertNil(pattern.firstMatch(in: text, range: range), text)
            }
        }
    }
}
