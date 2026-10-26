import Foundation
import notify

/// Darwin-notify signals between the app and the tunnel extension (see
/// docs/LOGGING.md, category `ipc`). A signal carries no payload: the
/// receiver re-reads shared state from the App Group.
public enum TunnelSignal: String, Sendable, CaseIterable {
    case settingsChanged = "net.renalias.adblocker.settings-changed"
    case blocklistChanged = "net.renalias.adblocker.blocklist-changed"

    private static let log = Log(category: "ipc")

    /// Posts the signal to every process observing it.
    public static func post(_ signal: TunnelSignal) {
        log.debug("signal posted: \(signal.rawValue)")
        notify_post(signal.rawValue)
    }

    /// Registers `handler` for `signal`. Throws `ObserverError` when the
    /// Darwin center rejects the registration.
    public static func observe(
        _ signal: TunnelSignal,
        queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) throws -> Observer {
        try Observer(signal: signal, queue: queue, handler: handler)
    }

    public struct ObserverError: Error, CustomStringConvertible, Sendable {
        public let signal: TunnelSignal
        public let status: UInt32

        public var description: String {
            "failed to observe \(signal.rawValue): notify status \(status)"
        }
    }

    /// A live registration. Cancelling or releasing it unregisters; once
    /// cancelled the handler is never called again.
    public final class Observer: @unchecked Sendable {
        private let lock = NSLock()
        private var token: Int32 = 0
        private var cancelled = false

        init(signal: TunnelSignal, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) throws {
            var newToken: Int32 = 0
            let status = notify_register_dispatch(signal.rawValue, &newToken, queue) { [weak self] _ in
                guard let self, self.isActive else { return }
                handler()
            }
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                throw ObserverError(signal: signal, status: status)
            }
            token = newToken
        }

        private var isActive: Bool {
            lock.lock(); defer { lock.unlock() }
            return !cancelled
        }

        public func cancel() {
            lock.lock()
            let wasCancelled = cancelled
            cancelled = true
            lock.unlock()
            if !wasCancelled { notify_cancel(token) }
        }

        deinit { cancel() }
    }
}
