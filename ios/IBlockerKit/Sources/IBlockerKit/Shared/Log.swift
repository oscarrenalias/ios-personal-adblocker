import Foundation
#if canImport(os)
import os
#endif

/// Thin logging wrapper (see docs/LOGGING.md). Uses `os.Logger` on Apple
/// platforms and does nothing elsewhere, so IBlockerKit still builds and
/// tests on Linux.
///
/// Messages are logged with `privacy: .public`, so callers decide what goes
/// in: domain names and IP addresses only at `debug`, never above.
/// Messages are autoclosures. Each level method first asks
/// `OSLog.isEnabled(type:)` and returns without evaluating the closure when
/// that level is not being collected, so per-query debug calls cost only the
/// check.
public struct Log: Sendable {
    public static let subsystem = "com.iblocker"

    #if canImport(os)
    private let logger: Logger
    private let osLog: OSLog
    /// Test seam: replaces the `OSLog.isEnabled(type:)` check when set.
    private let isEnabledOverride: (@Sendable (OSLogType) -> Bool)?
    #endif

    public init(category: String) {
        #if canImport(os)
        logger = Logger(subsystem: Log.subsystem, category: category)
        osLog = OSLog(subsystem: Log.subsystem, category: category)
        isEnabledOverride = nil
        #endif
    }

    #if canImport(os)
    init(category: String, isEnabled: @escaping @Sendable (OSLogType) -> Bool) {
        logger = Logger(subsystem: Log.subsystem, category: category)
        osLog = OSLog(subsystem: Log.subsystem, category: category)
        isEnabledOverride = isEnabled
    }

    private func isEnabled(_ type: OSLogType) -> Bool {
        if let isEnabledOverride { return isEnabledOverride(type) }
        return osLog.isEnabled(type: type)
    }
    #endif

    public func error(_ message: @autoclosure () -> String) {
        #if canImport(os)
        guard isEnabled(.error) else { return }
        let text = message()
        logger.error("\(text, privacy: .public)")
        #endif
    }

    public func notice(_ message: @autoclosure () -> String) {
        #if canImport(os)
        guard isEnabled(.default) else { return }
        let text = message()
        logger.notice("\(text, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        #if canImport(os)
        guard isEnabled(.info) else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        #if canImport(os)
        guard isEnabled(.debug) else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }
}
