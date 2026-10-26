import Network
import NetworkExtension
import os
import UserNotifications
import WidgetKit
import IBlockerKit
import IBlockerTunnelKit

/// The on-device DNS filter. A split tunnel routes ONLY the fake resolver
/// addresses (198.18.0.2 / fd00::2) into the utun, so all real traffic stays
/// on the physical interface; the provider answers blocked lookups itself
/// and forwards the rest to the configured upstream.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private static let log = Log(category: "tunnel")
    private static let pathLog = Log(category: "path")

    /// Read from router status callbacks and the path monitor queue, written
    /// on start / stop, so it lives behind a lock.
    private let engineBox = LockedBox<DNSProxyEngine?>(nil)
    private var engine: DNSProxyEngine? {
        get { engineBox.withValue { $0 } }
        set { engineBox.withValue { $0 = newValue } }
    }
    /// Read from the path monitor queue (networkChanged) and written on
    /// start / IPC / recovery, so it lives behind a lock.
    private let routerBox = LockedBox<ResolverRouter?>(nil)
    private var router: ResolverRouter? {
        get { routerBox.withValue { $0 } }
        set { routerBox.withValue { $0 = newValue } }
    }
    private var paths: AppGroupPaths?
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceObservers: [TunnelSignal.Observer] = []
    private let maintenanceQueue = DispatchQueue(label: "net.renalias.adblocker.tunnel.maintenance")
    private var pathMonitor: NWPathMonitor?
    /// Rate-limits blob load error logs (once per distinct error per 60 s).
    private let errorLimiter = LockedBox(ErrorLogLimiter(interval: 60))
    private let physicalInterface = InterfaceIndexBox()
    private let pathQueue = DispatchQueue(label: "net.renalias.adblocker.tunnel.path")
    private let notifier = StatusNotifier()
    /// Bumped by every `makeRouter`; callbacks from older routers are dropped.
    private let routerGeneration = LockedBox(0)
    /// Last (state, name) the widget was told about. Guards the write, the
    /// gate decision and the reload so concurrent publishes can't interleave.
    private let widgetPublished = LockedBox<WidgetReloadGate.Published?>(nil)

    /// Mirrors `status` into the shared settings and reloads the widget
    /// timeline only when the gate says the visible line changed.
    /// `status` is read inside the critical section, and a non-nil `generation`
    /// is re-checked there, so a late callback from a replaced router can't
    /// publish after (or over) a newer router's value.
    private func publishWidgetStatus(generation: Int? = nil, _ status: () -> ResolverStatus?) {
        guard let settings = AppGroupPaths.groupID(from: Bundle.main).flatMap({ SharedSettings(groupID: $0) }) else {
            Self.log.error("widget resolver status not published: app group unavailable")
            return
        }
        widgetPublished.withValue { last in
            if let generation, routerGeneration.withValue({ $0 }) != generation {
                Self.log.info("widget resolver status ignored: replaced router")
                return
            }
            let status = status()
            do {
                try settings.writeWidgetResolverStatus(status)
            } catch {
                Self.log.error("widget resolver status write failed: \(error)")
                return
            }
            let decision = WidgetReloadGate.evaluate(last: last, status: status)
            last = decision.published
            let state = decision.published.state
            guard decision.shouldReload else {
                Self.log.debug("widget resolver status unchanged (\(state)), no reload")
                return
            }
            Self.log.info("widget resolver status: \(state) (\(decision.published.name ?? "none"))")
            Self.reloadWidget(reason: "change")
        }
    }

    /// Unconditional reload for tunnel start and stop.
    private func reloadWidget(reason: String) {
        widgetPublished.withValue { _ in Self.reloadWidget(reason: reason) }
    }

    /// Stop: clears the value, resets the gate and reloads unconditionally.
    private func clearWidgetStatus() {
        if let groupID = AppGroupPaths.groupID(from: Bundle.main),
           let settings = SharedSettings(groupID: groupID) {
            widgetPublished.withValue { last in
                do {
                    try settings.writeWidgetResolverStatus(nil)
                } catch {
                    Self.log.error("widget resolver status clear failed: \(error)")
                }
                last = nil
                Self.reloadWidget(reason: "stop")
            }
        } else {
            Self.log.error("widget resolver status not cleared: app group unavailable")
            widgetPublished.withValue { last in
                last = nil
                Self.reloadWidget(reason: "stop")
            }
        }
    }

    private static func reloadWidget(reason: String) {
        log.debug("widget reload requested (\(reason))")
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.statusWidget)
    }

    /// Drives status notification events 1-4, 6 and 7 through the policy and poster.
    /// An actor so router callbacks, IPC and start/stop don't interleave
    /// their load-decide-save of the shared episode state.
    private actor StatusNotifier {
        private let log = Log(category: "notify")
        private var running = false
        /// Last alternative resolver name seen, so a restore can name it.
        private var lastResolverName: String?

        /// Last pause deadline handed to the policy, so unchanged deadlines
        /// don't reload and save the episode state every tick.
        private var lastPauseDeadline: Date??
        /// Event 7 is wanted but the shared settings were unreadable when
        /// the tunnel started degraded; retried until they can be read.
        private var degradedStartPending = false
        /// Same for events 4 and the user-off marker reset: the tunnel started
        /// before settings were readable.
        private var tunnelStartPending = false

        func tunnelStarting() {
            running = true
            lastPauseDeadline = nil
            degradedStartPending = false
            tunnelStartPending = false
        }

        /// Event 7: starts the 5 min degraded debounce.
        func degradedStarted() async {
            guard running else { return }
            if await run([.problemStarted(.degraded)], resolverName: nil) {
                degradedStartPending = false
            } else {
                degradedStartPending = true
                log.debug("degraded notification deferred: settings unreadable")
            }
        }

        /// Retries deferred start events once settings are readable.
        func retryDeferredStart() async {
            if tunnelStartPending {
                log.debug("retrying deferred tunnel start notification")
                await tunnelStarted()
            }
            guard degradedStartPending else { return }
            await degradedStarted()
        }

        /// Cancels a pending event 7, or posts its restore (event 4).
        func degradedEnded() async {
            degradedStartPending = false
            await run([.problemCleared(.degraded)], resolverName: nil)
        }

        /// Event 6: schedules, replaces or removes the pause-ended request.
        func pauseDeadlineChanged(_ deadline: Date?) async {
            guard running else { return }
            if let last = lastPauseDeadline, last == deadline { return }
            if await run([.pauseDeadline(deadline)], resolverName: nil) {
                lastPauseDeadline = .some(deadline)
            }
        }

        func resolverStatusChanged(_ status: ResolverStatus) async {
            guard running else {
                log.debug("resolver status change ignored: tunnel not running")
                return
            }
            let name: String?
            let events: [StatusNotificationEvent]
            switch status {
            case .fallingBack(let n):
                name = n
                events = [.problemStarted(.resolverFallback)]
            case .failing(let n):
                name = n
                events = [.problemStarted(.resolverFailing)]
            case .alternative(let n, _):
                name = n
                events = [.problemCleared(.resolverFallback), .problemCleared(.resolverFailing)]
            case .network:
                // Alternative turned off: end the episodes without a restore.
                name = nil
                events = [.problemDismissed(.resolverFallback), .problemDismissed(.resolverFailing)]
                log.info("resolver episodes dismissed: alternative turned off")
            }
            if let name { lastResolverName = name }
            await run(events, resolverName: name ?? lastResolverName)
        }

        /// Event 3 on an unexpected stop; always ends pending 1, 2, 6, 7.
        func tunnelStopped(reason: NEProviderStopReason) async {
            running = false
            let stopReason = TunnelStopReason(rawValue: reason.rawValue)
            let settings = Self.settings()
            if stopReason == .userInitiated, let settings {
                // e.g. VPN switched off in iOS Settings: the app never sees
                // this stop, so mark it or checkTunnelGone raises a false alarm.
                settings.userTurnedOff = true
                log.notice("user-off marker set: stop reason userInitiated")
            }
            let marker = settings?.userTurnedOff ?? false
            let classification = StatusNotificationPolicy.classifyStop(reason: stopReason, userTurnedOffMarker: marker)
            log.notice("stop classified \(classification == .expected ? "expected" : "unexpected"): reason \(stopReason.logName), user-off marker \(marker ? "set" : "clear")")
            var events: [StatusNotificationEvent] = [.tunnelStopped]
            if classification == .unexpected { events.append(.problemStarted(.protectionStopped)) }
            await run(events, resolverName: nil)
        }

        /// Cancels a pending event 3, or posts its restore (event 4).
        func tunnelStarted() async {
            running = true
            guard let settings = Self.settings(), settings.settingsAvailable else {
                tunnelStartPending = true
                log.debug("tunnel start notification deferred: settings unreadable")
                return
            }
            // Protection is on, whoever started it (e.g. the iOS Settings toggle).
            if settings.userTurnedOff {
                settings.userTurnedOff = false
                log.notice("user-off marker cleared: tunnel started")
            }
            if await run([.problemCleared(.protectionStopped)], resolverName: nil) {
                tunnelStartPending = false
            } else {
                tunnelStartPending = true
                log.debug("tunnel start notification deferred: settings unreadable")
            }
        }

        private static func settings() -> SharedSettings? {
            AppGroupPaths.groupID(from: Bundle.main).flatMap { SharedSettings(groupID: $0) }
        }

        /// Returns false when the events were skipped (settings unavailable).
        @discardableResult
        private func run(_ events: [StatusNotificationEvent], resolverName: String?) async -> Bool {
            guard let settings = Self.settings() else {
                log.error("notification events skipped: shared settings unavailable")
                return false
            }
            guard settings.settingsAvailable else {
                log.debug("notification events skipped: settings not yet readable")
                return false
            }
            var state = StatusNotificationState.load(from: settings)
            let preferences = StatusNotificationPreferences(settings: settings)
            let now = Date()
            var decisions: [StatusNotificationDecision] = []
            for event in events {
                let decision = StatusNotificationPolicy.decide(event: event, state: state, preferences: preferences, now: now)
                state = decision.state
                decisions.append(decision)
            }
            state.save(to: settings)
            let poster = NotificationPoster(preferences: {
                Self.settings().map { StatusNotificationPreferences(settings: $0) }
                    ?? StatusNotificationPreferences(masterEnabled: false)
            })
            for decision in decisions {
                await poster.execute(decision, now: now, resolverName: resolverName)
            }
            return true
        }
    }

    /// Thread-safe holder for the current physical interface index, written
    /// from the path monitor queue and read from upstream resolves.
    private final class InterfaceIndexBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt32?

        func get() -> UInt32? {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func set(_ newValue: UInt32?) {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }
    }

    private final class LockedBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func withValue<R>(_ body: (inout T) -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return body(&value)
        }
    }

    /// Builds the upstream; `.network` is backed by the live path-monitor
    /// interface so Wi-Fi ↔ cellular switches apply without a tunnel restart.
    private func makeUpstream(_ config: UpstreamConfig) -> DNSUpstream? {
        let box = physicalInterface
        return UpstreamFactory.make(config, interfaceIndex: { box.get() })
    }

    /// Builds a router: network DNS plus the alternative when the toggle is on.
    /// Returns nil (with an error log) when an upstream cannot be built.
    private func makeRouter(_ settings: ResolverSettings, source: String) -> ResolverRouter? {
        guard let network = makeUpstream(UpstreamConfig(kind: .network)) else {
            Self.log.error("resolver settings not applied (source \(source)): network upstream could not be built")
            return nil
        }
        var alternative: ResolverRouter.Alternative?
        if settings.useAlternative {
            guard let upstream = makeUpstream(settings.alternative) else {
                Self.log.error("resolver settings not applied (source \(source)): alternative upstream could not be built, kind \(String(describing: settings.alternative.kind))")
                return nil
            }
            alternative = (upstream, settings.alternativeName, settings.alternative.isEncrypted)
        }
        let notifier = notifier
        let engineBox = engineBox
        let generation = routerGeneration.withValue { $0 += 1; return $0 }
        let generationBox = routerGeneration
        let notifyLog = Log(category: "notify")
        let router = ResolverRouter(
            network: network,
            alternative: alternative,
            policy: settings.fallbackPolicy,
            onStatusChange: { [weak self] status in
                // In-flight probes/queries of a replaced router can still report.
                guard generationBox.withValue({ $0 }) == generation else {
                    notifyLog.info("ignored status change from replaced router")
                    return
                }
                self?.publishWidgetStatus(generation: generation) { status }
                if let engine = engineBox.withValue({ $0 }) {
                    Task { await engine.clearCache(reason: .resolverStatusChange) }
                }
                Task { await notifier.resolverStatusChanged(status) }
            }
        )
        Self.log.notice("resolver settings applied: source \(source), alternative \(settings.useAlternative ? "on" : "off"), name \(settings.alternativeName), url \(settings.alternative.displayName), policy \(settings.fallbackPolicy.rawValue)")
        return router
    }

    /// Tracks the first Wi-Fi / cellular / wired interface. `.other` is
    /// deliberately excluded: that is the tunnel's own utun.
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let box = physicalInterface
        let routerBox = routerBox
        let engineBox = engineBox
        let monitor = NWPathMonitor()
        // Only touched from the path monitor queue.
        var previous: String = "none"
        monitor.pathUpdateHandler = { path in
            let selected = path.availableInterfaces.first {
                $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet
            }
            box.set(selected.map { UInt32($0.index) })
            let current = selected.map { Self.describe($0) } ?? "none"
            if current != previous {
                Self.pathLog.info("selected interface \(previous) → \(current), path status \(String(describing: path.status))")
                previous = current
                // Only a selected-interface change resets the router's
                // network-DNS state (circuit breaker / probe).
                routerBox.withValue { $0 }?.networkChanged()
                if let engine = engineBox.withValue({ $0 }) {
                    Task { await engine.clearCache(reason: .networkChange) }
                }
            }
            if selected == nil {
                let types = path.availableInterfaces.map { String(describing: $0.type) }.joined(separator: ", ")
                Self.pathLog.notice("no usable physical interface, path status \(String(describing: path.status)), available interface types [\(types)]")
            }
        }
        monitor.start(queue: pathQueue)
        pathMonitor = monitor
    }

    private static func describe(_ interface: NWInterface) -> String {
        "\(interface.name) (index \(interface.index), \(String(describing: interface.type)))"
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let groupID = AppGroupPaths.groupID(from: Bundle.main),
              let paths = AppGroupPaths(groupID: groupID) else {
            Self.log.error("missing AppGroupID / container — check entitlements")
            throw NEVPNError(.configurationInvalid)
        }
        self.paths = paths
        try? paths.ensureDirectories()
        await notifier.tunnelStarting()
        // Removal needs no shared state, so it works before first unlock too.
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [StatusNotificationKind.protectionStopped.notificationIdentifier])

        let settings = SharedSettings(groupID: groupID)
        let settingsReadable = settings?.settingsAvailable ?? false
        // While settings are unreadable (before first unlock) start with
        // defaults (alternative off); the recovery tick rebuilds the router.
        let resolverSettings = settingsReadable ? (settings?.resolverSettings ?? .default) : .default
        startPathMonitor()
        guard let router = makeRouter(resolverSettings, source: "start") else {
            pathMonitor?.cancel()
            pathMonitor = nil
            throw NEVPNError(.configurationInvalid)
        }

        let (matcher, blobFailures) = currentMatcher(paths: paths)
        let recovery = TunnelRecovery(settingsReadable: settingsReadable, blocklistLoaded: blobFailures.isEmpty)
        if recovery.isDegraded {
            var unavailable: [String] = []
            if recovery.settingsPending { unavailable.append("settings") }
            if recovery.blocklistPending { unavailable.append("blocklist (\(blobFailures.map(\.fileName).joined(separator: ", ")))") }
            Self.log.notice("starting degraded, unavailable: \(unavailable.joined(separator: ", ")); will retry every 2 s")
        }
        let startedAt = Date()
        let engine = DNSProxyEngine(
            matcher: matcher,
            upstream: router,
            logWriter: try? QueryLogRingWriter(url: paths.queryLogURL),
            statsURL: paths.statsURL,
            configuration: .init(logEnabled: settings?.queryLogEnabled ?? true)
        )
        await engine.setPaused(until: settings?.pausedUntil)
        Self.applyVerbose(until: settings?.verboseLoggingUntil)
        self.engine = engine
        self.router = router

        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let relayStrategy = settings?.effectiveRelayStrategy ?? .blockDomains

        let ipv4 = NEIPv4Settings(
            addresses: [TunnelConstants.tunnelIPv4],
            subnetMasks: [TunnelConstants.tunnelIPv4SubnetMask]
        )
        let dnsRoute4 = NEIPv4Route(destinationAddress: TunnelConstants.dnsIPv4, subnetMask: "255.255.255.255")
        if relayStrategy == .autoSuspend {
            // Claim the default route so iOS treats this as a full VPN and
            // suspends Private Relay / tracker relaying itself — but exclude
            // both halves of the address space with more-specific routes, so
            // real traffic never enters the tunnel. Only the /32 DNS route
            // (more specific than the /1 exclusions) still comes to us.
            ipv4.includedRoutes = [NEIPv4Route.default(), dnsRoute4]
            ipv4.excludedRoutes = [
                NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "128.0.0.0"),
                NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"),
            ]
        } else {
            ipv4.includedRoutes = [dnsRoute4]
        }
        networkSettings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: [TunnelConstants.tunnelIPv6],
            networkPrefixLengths: [NSNumber(value: TunnelConstants.tunnelIPv6PrefixLength)]
        )
        let dnsRoute6 = NEIPv6Route(destinationAddress: TunnelConstants.dnsIPv6, networkPrefixLength: 128)
        if relayStrategy == .autoSuspend {
            ipv6.includedRoutes = [NEIPv6Route.default(), dnsRoute6]
            ipv6.excludedRoutes = [
                NEIPv6Route(destinationAddress: "::", networkPrefixLength: 1),
                NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1),
            ]
        } else {
            ipv6.includedRoutes = [dnsRoute6]
        }
        networkSettings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [TunnelConstants.dnsIPv4, TunnelConstants.dnsIPv6])
        dns.matchDomains = [""]  // make the tunnel the default resolver for everything
        networkSettings.dnsSettings = dns
        networkSettings.mtu = NSNumber(value: TunnelConstants.mtu)

        try await setTunnelNetworkSettings(networkSettings)
        settings?.protectionActive = true
        publishWidgetStatus { settingsReadable ? router.status : nil }
        reloadWidget(reason: "start")
        await notifier.tunnelStarted()
        if recovery.isDegraded { await notifier.degradedStarted() }

        Self.log.notice("tunnel up — \(matcher.blockedEntryCount) rules, resolver \(resolverSettings.useAlternative ? resolverSettings.alternativeName : "Network DNS"), available memory \(os_proc_available_memory())")

        startPacketLoop()
        startMaintenance(paths: paths, recovery: recovery, startedAt: startedAt)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.log.notice("tunnel stopping: \(String(describing: reason))")
        maintenanceObservers.forEach { $0.cancel() }
        maintenanceObservers = []
        maintenanceTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        physicalInterface.set(nil)
        if let groupID = AppGroupPaths.groupID(from: Bundle.main),
           let settings = SharedSettings(groupID: groupID) {
            settings.protectionActive = false
        }
        clearWidgetStatus()
        await notifier.tunnelStopped(reason: reason)
        if let engine {
            await engine.flush()
        }
        engine = nil
        router = nil
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let engine else { return nil }
        let request: TunnelRequest
        do {
            request = try TunnelIPCCoder.decodeRequest(messageData)
        } catch {
            Self.log.error("IPC request not decoded (possibly setResolverSettings), reason: \(String(describing: error))")
            return nil
        }

        let response: TunnelResponse
        switch request {
        case .ping:
            response = .ok

        case .reloadRules:
            if let paths {
                await engine.reload(matcher: currentMatcher(paths: paths).matcher)
                response = .ok
            } else {
                response = .failure("no app group container")
            }

        case .getStats:
            await engine.flush()
            var stats = await engine.statsSnapshot(memoryBytes: UInt64(os_proc_available_memory()))
            stats.resolverStatus = router?.status
            response = .stats(stats)

        case .setResolverSettings(let resolverSettings):
            if let newRouter = makeRouter(resolverSettings, source: "ipc") {
                await engine.setUpstream(newRouter)
                router = newRouter
                publishWidgetStatus { newRouter.status }
                await notifier.resolverStatusChanged(newRouter.status)
                response = .ok
            } else {
                response = .failure("invalid resolver settings")
            }

        case .setPause(let until):
            if let groupID = AppGroupPaths.groupID(from: Bundle.main),
               let settings = SharedSettings(groupID: groupID) {
                settings.pausedUntil = until
            }
            await engine.setPaused(until: until)
            await notifier.pauseDeadlineChanged(until)
            response = .ok

        case .clearDNSCache:
            Self.log.info("IPC clearDNSCache")
            await engine.clearCache(reason: .user)
            response = .ok

        case .flushLog:
            await engine.flush()
            response = .ok
        }
        return try? TunnelIPCCoder.encode(response)
    }

    /// The matcher is the on-disk blobs PLUS the in-memory seed fallback for
    /// every bundled source the user has left enabled — so the guaranteed
    /// floor (in-app Google ads, Apple tracker-relay bypass) holds even when
    /// the compiled blob is missing or stale.
    /// Blob load failures are logged at error level (rate limited) and
    /// returned so callers can track degraded state.
    private func currentMatcher(paths: AppGroupPaths) -> (matcher: DomainMatcher, failures: [AppGroupPaths.BlobLoadFailure]) {
        let state = FilterListState.load(from: paths.filterStateURL)
        let result = paths.loadMatcherReportingFailures(builtInBlockHashes: SeedRules.fallbackHashes(state: state))
        for failure in result.failures {
            let key = "\(failure.fileName): \(failure.error)"
            if errorLimiter.withValue({ $0.shouldLog(key) }) {
                Self.log.error("blocklist load failed: \(failure.fileName), error: \(failure.error)")
            }
        }
        if let blocklist = result.matcher.blocklist, blocklist.formatVersion == CompiledBlocklist.legacyFormatVersion {
            Self.log.notice("blocklist v1 loaded (no attribution); waiting for recompile")
        }
        return result
    }

    /// A list exceptions blob is only usable alongside the blocklist it was
    /// compiled with. A missing exceptions blob is accepted (no exceptions).
    /// Returns the generations when they disagree, nil when the pair is usable.
    static func exceptionsGenerationMismatch(for matcher: DomainMatcher) -> (exceptions: UInt32, blocklist: UInt32)? {
        guard let exceptions = matcher.listAllowlist, let blocklist = matcher.blocklist,
              exceptions.generation != blocklist.generation else { return nil }
        return (exceptions.generation, blocklist.generation)
    }

    // MARK: - Packet loop

    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            for packet in packets {
                Task { [weak self] in
                    guard let self, let engine = self.engine else { return }
                    let replies = await engine.handlePacket(packet)
                    if !replies.isEmpty {
                        let protocols = replies.map { NSNumber(value: (([UInt8]($0).first ?? 0) >> 4) == 6 ? AF_INET6 : AF_INET) }
                        self.packetFlow.writePackets(replies, withProtocols: protocols)
                    }
                }
            }
            self.startPacketLoop()
        }
    }

    // MARK: - Maintenance

    /// Syncs the process-wide verbose flag with the shared setting and logs
    /// a notice when it changes.
    private static func applyVerbose(until: Date?) {
        let on = until != nil
        guard on != Log.isVerbose else { return }
        Log.setVerbose(on)
        if let until {
            log.notice("verbose logging on until \(until.formatted(.iso8601))")
        } else {
            log.notice("verbose logging off")
        }
    }

    /// One task sleeps until the schedule's next timer wake or a Darwin
    /// signal (settings / blocklist changed), then runs one pass. Signals
    /// arriving during a pass coalesce into a single follow-up pass.
    /// Idle passes run every 60 s; while degraded (started before first
    /// unlock) every 2 s, retrying the unreadable settings and blobs.
    private func startMaintenance(paths: AppGroupPaths, recovery initial: TunnelRecovery, startedAt: Date) {
        let groupID = AppGroupPaths.groupID(from: Bundle.main)
        let pending = LockedBox(Set<MaintenanceSchedule.WakeReason>())
        let (wakeStream, wakeContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let post: @Sendable (MaintenanceSchedule.WakeReason) -> Void = { reason in
            pending.withValue { _ = $0.insert(reason) }
            wakeContinuation.yield()
        }

        maintenanceObservers.forEach { $0.cancel() }
        maintenanceObservers = []
        let signals: [(TunnelSignal, MaintenanceSchedule.WakeReason, String)] = [
            (.settingsChanged, .settings, "settingsChanged"),
            (.blocklistChanged, .blocklist, "blocklistChanged"),
        ]
        for (signal, reason, name) in signals {
            do {
                let observer = try TunnelSignal.observe(signal, queue: maintenanceQueue) {
                    Self.log.debug("signal received: \(name)")
                    post(reason)
                }
                maintenanceObservers.append(observer)
            } catch {
                Self.log.error("maintenance signal observer failed, timer only: \(String(describing: error))")
            }
        }

        maintenanceTask = Task { [weak self] in
            var recovery = initial
            var schedule = MaintenanceSchedule(degraded: recovery.isDegraded, now: Date())
            var verboseUntil: Date?
            var lastLoggedInterval: TimeInterval?
            var counts: [MaintenanceSchedule.WakeReason: Int] = [:]
            var passes = 0
            var summaryAt = Date()

            func logInterval(_ degraded: Bool) {
                let interval = MaintenanceSchedule.interval(degraded: degraded)
                guard interval != lastLoggedInterval else { return }
                lastLoggedInterval = interval
                Self.log.notice("maintenance interval \(Int(interval)) s (\(degraded ? "degraded" : "idle"))")
            }
            logInterval(recovery.isDegraded)

            var iterator = wakeStream.makeAsyncIterator()
            while !Task.isCancelled {
                let wakeAt = schedule.wake(now: Date(), verboseLoggingUntil: verboseUntil)
                let delay = max(0, wakeAt.timeIntervalSinceNow)
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    post(.timer)
                }
                _ = await iterator.next()
                timer.cancel()
                if Task.isCancelled { return }
                let reasons = pending.withValue { set -> Set<MaintenanceSchedule.WakeReason> in
                    defer { set.removeAll() }
                    return set
                }
                guard !reasons.isEmpty else { continue }
                guard let self, let engine = self.engine else { return }

                // Plan one pass covering every coalesced reason.
                var steps: [MaintenanceSchedule.Step] = []
                let now = Date()
                for reason in [MaintenanceSchedule.WakeReason.timer, .settings, .blocklist] where reasons.contains(reason) {
                    let plan = schedule.plan(reason: reason, degraded: recovery.isDegraded,
                                             now: now, verboseLoggingUntil: verboseUntil)
                    for step in plan.steps where !steps.contains(step) { steps.append(step) }
                    counts[reason, default: 0] += 1
                }
                passes += 1
                logInterval(schedule.degraded)
                let signalTriggered = !reasons.contains(.timer)

                if steps.contains(.flush) { await engine.flush() }

                let settings = groupID.flatMap { SharedSettings(groupID: $0) }
                let settingsReadable = settings?.settingsAvailable ?? false

                if steps.contains(.settings) {
                    // Re-read the pause deadline so a pause set by the widget
                    // or an App Intent (which can't reach the tunnel over IPC)
                    // propagates within one pass.
                    if let settings, settingsReadable || !recovery.settingsPending {
                        await engine.setPaused(until: settings.pausedUntil)
                        await self.notifier.pauseDeadlineChanged(settings.pausedUntil)
                        verboseUntil = settings.verboseLoggingUntil
                        Self.applyVerbose(until: verboseUntil)
                        if settingsReadable { await self.notifier.retryDeferredStart() }
                    }
                }

                var reloaded: DomainMatcher?
                if steps.contains(.recovery), recovery.isDegraded {
                    var blocklistReadable = false
                    if recovery.blocklistPending {
                        let result = self.currentMatcher(paths: paths)
                        if result.failures.isEmpty {
                            blocklistReadable = true
                            reloaded = result.matcher
                        }
                    }
                    let actions = recovery.tick(settingsReadable: settingsReadable,
                                                blocklistReadable: blocklistReadable)
                    var upstreamName = "unchanged"
                    if actions.reapplySettings, let settings {
                        let resolverSettings = settings.resolverSettings
                        if let newRouter = self.makeRouter(resolverSettings, source: "recovery") {
                            await engine.setUpstream(newRouter)
                            self.router = newRouter
                            self.publishWidgetStatus { newRouter.status }
                            await self.notifier.resolverStatusChanged(newRouter.status)
                            upstreamName = resolverSettings.useAlternative ? resolverSettings.alternativeName : "Network DNS"
                        }
                        await engine.setLogEnabled(settings.queryLogEnabled)
                        await engine.setPaused(until: settings.pausedUntil)
                        verboseUntil = settings.verboseLoggingUntil
                        Self.applyVerbose(until: verboseUntil)
                    }
                    if let matcher = reloaded {
                        await engine.reload(matcher: matcher)
                        Self.log.info("blocklist reloaded: \(matcher.blockedEntryCount) rules, generation \(matcher.blocklist?.generation.description ?? "none")")
                    }
                    if !recovery.isDegraded {
                        let elapsed = Int(Date().timeIntervalSince(startedAt))
                        let rules = await engine.blockedEntryCount
                        Self.log.notice("recovered after \(elapsed) s: \(rules) rules, upstream \(upstreamName)")
                        await self.notifier.degradedEnded()
                    }
                }

                if steps.contains(.blocklistCheck), reloaded == nil, !recovery.blocklistPending {
                    let current = await engine.blocklistGeneration
                    do {
                        let onDisk = try CompiledBlocklistView(contentsOf: paths.blocklistURL)
                        if onDisk.generation != current {
                            let matcher = self.currentMatcher(paths: paths).matcher
                            if let mismatch = Self.exceptionsGenerationMismatch(for: matcher) {
                                Self.log.notice("list exceptions generation \(mismatch.exceptions) ≠ blocklist \(mismatch.blocklist), deferring reload")
                            } else {
                                await engine.reload(matcher: matcher)
                                Self.log.info("blocklist reloaded: \(matcher.blockedEntryCount) rules, generation \(onDisk.generation)\(signalTriggered ? " (signal)" : "")")
                            }
                        }
                    } catch {
                        // A missing file is normal before the first compile.
                        if FileManager.default.fileExists(atPath: paths.blocklistURL.path) {
                            let key = "\(paths.blocklistURL.lastPathComponent): \(String(describing: error))"
                            if self.errorLimiter.withValue({ $0.shouldLog(key) }) {
                                Self.log.error("blocklist load failed: \(paths.blocklistURL.lastPathComponent), error: \(String(describing: error))")
                            }
                        }
                    }
                }

                if Date().timeIntervalSince(summaryAt) >= 600 {
                    Self.log.info("maintenance: \(passes) passes (timer \(counts[.timer] ?? 0), settings \(counts[.settings] ?? 0), blocklist \(counts[.blocklist] ?? 0))")
                    passes = 0
                    counts = [:]
                    summaryAt = Date()
                }
            }
        }
    }
}
