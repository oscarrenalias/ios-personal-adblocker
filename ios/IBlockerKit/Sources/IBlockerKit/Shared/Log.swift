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
/// Messages are autoclosures and are only built when the level is emitted
/// by the caller's code path, keeping per-query debug calls cheap.
public struct Log: Sendable {
    public static let subsystem = "com.iblocker"

    #if canImport(os)
    private let logger: Logger
    #endif

    public init(category: String) {
        #if canImport(os)
        logger = Logger(subsystem: Log.subsystem, category: category)
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.error("\(text, privacy: .public)")
        #endif
    }

    public func notice(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.notice("\(text, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let text = message()
        logger.info("\(text, privacy: .public)")
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        #if canImport(os)
        // Avoid building the string when debug is not being streamed.
        let text = message()
        logger.debug("\(text, privacy: .public)")
        #endif
    }
}
