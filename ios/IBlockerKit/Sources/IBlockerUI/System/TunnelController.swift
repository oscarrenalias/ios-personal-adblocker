#if os(iOS)
import Foundation
import NetworkExtension
import Observation
import IBlockerKit

/// Owns the NETunnelProviderManager lifecycle and the IPC channel to the
/// running tunnel. Encodes the two classic NetworkExtension traps so no
/// caller can hit them:
///  - reload the manager after saving, or startVPNTunnel throws stale-config
///  - disable on-demand before stopping, or the system reconnects instantly
@MainActor
@Observable
public final class TunnelController {

    public enum State: Equatable {
        case unknown
        case notInstalled
        case disconnected
        case connecting
        case connected
        case disconnecting
        case permissionNeeded
    }

    public private(set) var state: State = .unknown
    public private(set) var lastError: String?
    public private(set) var runtimeStats: TunnelRuntimeStats?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var statsAvailable: Bool?
    private static let log = Log(category: "ipc")

    public init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.syncStatus() }
        }
        Task { await refresh() }
    }

    public var isOn: Bool { state == .connected || state == .connecting }
    public var isInstalled: Bool { manager != nil }

    public func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first
            syncStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func toggle() async {
        if isOn {
            await disable()
        } else {
            await enable()
        }
    }

    public func enable() async {
        do {
            let manager = try await ensureManager()
            AppEnvironment.settings.userTurnedOff = false
            manager.isEnabled = true
            manager.isOnDemandEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()
            lastError = nil
        } catch let error as NEVPNError where error.code == .configurationReadWriteFailed {
            state = .permissionNeeded
            lastError = "VPN permission was declined. Try again and tap Allow."
            return
        } catch {
            lastError = error.localizedDescription
        }
        syncStatus()
    }

    public func disable() async {
        guard let manager else { return }
        // Marker first, so the tunnel's stop is classified as user-initiated.
        AppEnvironment.settings.userTurnedOff = true
        do {
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
            manager.connection.stopVPNTunnel()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        syncStatus()
    }

    private static let configurationName = "Personal AdBlocker"

    private func ensureManager() async throws -> NETunnelProviderManager {
        if let manager {
            // Renamed on the next save so iOS Settings shows the current name.
            if manager.localizedDescription != Self.configurationName {
                manager.localizedDescription = Self.configurationName
            }
            return manager
        }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppEnvironment.tunnelBundleID
        proto.serverAddress = TunnelConstants.serverDescription
        manager.protocolConfiguration = proto
        manager.localizedDescription = Self.configurationName
        manager.onDemandRules = [NEOnDemandRuleConnect()]

        self.manager = manager
        return manager
    }

    private func syncStatus() {
        guard let manager else {
            if state != .permissionNeeded { state = .notInstalled }
            return
        }
        switch manager.connection.status {
        case .connected: state = .connected
        case .connecting, .reasserting: state = .connecting
        case .disconnecting: state = .disconnecting
        case .disconnected: state = .disconnected
        case .invalid: state = .notInstalled
        @unknown default: state = .unknown
        }
    }

    // MARK: - IPC

    public func send(_ request: TunnelRequest) async -> TunnelResponse? {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            Self.log.debug("ipc \(request): no tunnel session (manager \(manager == nil ? "nil" : "not a provider session"))")
            return nil
        }
        guard session.status == .connected else {
            Self.log.debug("ipc \(request): tunnel status is \(session.status.rawValue), not connected")
            return nil
        }
        let data: Data
        do {
            data = try TunnelIPCCoder.encode(request)
        } catch {
            Self.log.error("ipc \(request): encode failed: \(error)")
            return nil
        }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { reply in
                    guard let reply else {
                        Self.log.debug("ipc \(request): nil reply from tunnel")
                        continuation.resume(returning: nil)
                        return
                    }
                    do {
                        continuation.resume(returning: try TunnelIPCCoder.decodeResponse(reply))
                    } catch {
                        Self.log.error("ipc \(request): undecodable reply (\(reply.count) bytes): \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            } catch {
                Self.log.error("ipc \(request): sendProviderMessage threw: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    public func refreshStats() async {
        if case .stats(let stats)? = await send(.getStats) {
            runtimeStats = stats
            noteStatsAvailability(true)
        } else {
            // Stale numbers from a previous tunnel session must not linger.
            runtimeStats = nil
            noteStatsAvailability(false)
        }
    }

    /// Logs only on transitions; refreshStats polls every few seconds.
    private func noteStatsAvailability(_ available: Bool) {
        guard statsAvailable != available else { return }
        statsAvailable = available
        if available {
            Self.log.notice("tunnel stats available")
        } else {
            Self.log.notice("tunnel stats unavailable (state \(String(describing: state)))")
        }
    }

    public func reloadRules() async {
        _ = await send(.reloadRules)
    }

    public func setResolverSettings(_ settings: ResolverSettings) async {
        _ = await send(.setResolverSettings(settings))
    }

    /// Drops the tunnel's cached DNS answers, then refreshes the stats row.
    /// A tunnel that predates the cache never replies, so the row falls back
    /// to "Not available".
    public func clearDNSCache() async {
        switch await send(.clearDNSCache) {
        case .ok?:
            Self.log.notice("clearDNSCache requested")
        case .failure(let message)?:
            Self.log.error("clearDNSCache failed: \(message)")
        case .stats?, nil:
            Self.log.error("clearDNSCache failed: no reply (older tunnel?)")
        }
        await refreshStats()
    }

    // MARK: - Pause

    public var pausedUntil: Date? { runtimeStats?.pausedUntil }
    public var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    /// Suspends blocking for `minutes`, then it resumes on its own. Writes
    /// shared state (so a resume survives even if IPC is momentarily
    /// unavailable) and tells the live tunnel immediately.
    public func pause(minutes: Int) async {
        let until = Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
        AppEnvironment.settings.pausedUntil = until
        _ = await send(.setPause(until: until))
        await refreshStats()
        VPNControl.reloadWidgets()
    }

    public func resume() async {
        AppEnvironment.settings.pausedUntil = nil
        _ = await send(.setPause(until: nil))
        await refreshStats()
        VPNControl.reloadWidgets()
    }
}
#endif
