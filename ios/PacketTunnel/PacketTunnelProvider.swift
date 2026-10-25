import Network
import NetworkExtension
import os
import IBlockerKit
import IBlockerTunnelKit

/// The on-device DNS filter. A split tunnel routes ONLY the fake resolver
/// addresses (198.18.0.2 / fd00::2) into the utun, so all real traffic stays
/// on the physical interface; the provider answers blocked lookups itself
/// and forwards the rest to the configured upstream.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private static let log = Log(category: "tunnel")
    private static let pathLog = Log(category: "path")

    private var engine: DNSProxyEngine?
    /// Read from the path monitor queue (networkChanged) and written on
    /// start / IPC / recovery, so it lives behind a lock.
    private let routerBox = LockedBox<ResolverRouter?>(nil)
    private var router: ResolverRouter? {
        get { routerBox.withValue { $0 } }
        set { routerBox.withValue { $0 = newValue } }
    }
    private var paths: AppGroupPaths?
    private var maintenanceTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// Rate-limits blob load error logs (once per distinct error per 60 s).
    private let errorLimiter = LockedBox(ErrorLogLimiter(interval: 60))
    private let physicalInterface = InterfaceIndexBox()
    private let pathQueue = DispatchQueue(label: "com.iblocker.tunnel.path")

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
        let router = ResolverRouter(network: network, alternative: alternative, policy: settings.fallbackPolicy)
        Self.log.notice("resolver settings applied: source \(source), alternative \(settings.useAlternative ? "on" : "off"), name \(settings.alternativeName), url \(settings.alternative.displayName), policy \(settings.fallbackPolicy.rawValue)")
        return router
    }

    /// Tracks the first Wi-Fi / cellular / wired interface. `.other` is
    /// deliberately excluded: that is the tunnel's own utun.
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let box = physicalInterface
        let routerBox = routerBox
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

        Self.log.notice("tunnel up — \(matcher.blockedEntryCount) rules, resolver \(resolverSettings.useAlternative ? resolverSettings.alternativeName : "Network DNS"), available memory \(os_proc_available_memory())")

        startPacketLoop()
        startMaintenance(paths: paths, recovery: recovery, startedAt: startedAt)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.log.notice("tunnel stopping: \(String(describing: reason))")
        maintenanceTask?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        physicalInterface.set(nil)
        if let groupID = AppGroupPaths.groupID(from: Bundle.main),
           let settings = SharedSettings(groupID: groupID) {
            settings.protectionActive = false
        }
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
        return result
    }

    // MARK: - Packet loop

    private func startPacketLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            for packet in packets {
                Task { [weak self] in
                    guard let self, let engine = self.engine else { return }
                    if let reply = await engine.handlePacket(packet) {
                        let family = (([UInt8](reply).first ?? 0) >> 4) == 6 ? AF_INET6 : AF_INET
                        self.packetFlow.writePackets([reply], withProtocols: [NSNumber(value: family)])
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

    /// Flushes the log/stats every 2 s and picks up recompiled blocklists
    /// even if the app's reload IPC never arrives (e.g. app was killed).
    /// While degraded (started before first unlock) it also retries the
    /// unreadable settings and blobs on every tick.
    private func startMaintenance(paths: AppGroupPaths, recovery initial: TunnelRecovery, startedAt: Date) {
        let groupID = AppGroupPaths.groupID(from: Bundle.main)
        maintenanceTask = Task { [weak self] in
            var tick: UInt64 = 0
            var recovery = initial
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let engine = self.engine else { return }
                await engine.flush()

                let settings = groupID.flatMap { SharedSettings(groupID: $0) }
                let settingsReadable = settings?.settingsAvailable ?? false

                // Re-read the pause deadline so a pause set by the widget or
                // an App Intent (which can't reach the tunnel over IPC)
                // propagates within one tick.
                if let settings, settingsReadable || !recovery.settingsPending {
                    await engine.setPaused(until: settings.pausedUntil)
                    Self.applyVerbose(until: settings.verboseLoggingUntil)
                }

                var reloaded: DomainMatcher?
                if recovery.isDegraded {
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
                            upstreamName = resolverSettings.useAlternative ? resolverSettings.alternativeName : "Network DNS"
                        }
                        await engine.setLogEnabled(settings.queryLogEnabled)
                        await engine.setPaused(until: settings.pausedUntil)
                        Self.applyVerbose(until: settings.verboseLoggingUntil)
                    }
                    if let matcher = reloaded {
                        await engine.reload(matcher: matcher)
                        Self.log.info("blocklist reloaded: \(matcher.blockedEntryCount) rules, generation \(matcher.blocklist?.generation.description ?? "none")")
                    }
                    if !recovery.isDegraded {
                        let elapsed = Int(Date().timeIntervalSince(startedAt))
                        let rules = await engine.blockedEntryCount
                        Self.log.notice("recovered after \(elapsed) s: \(rules) rules, upstream \(upstreamName)")
                    }
                }

                tick += 1
                if tick % 5 == 0, reloaded == nil, !recovery.blocklistPending {
                    let current = await engine.blocklistGeneration
                    do {
                        let onDisk = try CompiledBlocklistView(contentsOf: paths.blocklistURL)
                        if onDisk.generation != current {
                            let matcher = self.currentMatcher(paths: paths).matcher
                            await engine.reload(matcher: matcher)
                            Self.log.info("blocklist reloaded: \(matcher.blockedEntryCount) rules, generation \(onDisk.generation)")
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
            }
        }
    }
}
