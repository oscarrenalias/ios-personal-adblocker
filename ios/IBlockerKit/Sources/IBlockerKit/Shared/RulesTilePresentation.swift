import Foundation

/// What the Dashboard's Rules tile shows. The live count comes only from the
/// running tunnel; the compiled file's count is context, never a substitute.
public enum RulesTilePresentation: Equatable, Sendable {
    /// The tunnel's live stats can't be reached.
    case unavailable
    /// Live count, with the compiled file's count when it is larger
    /// (a partially loaded tunnel).
    case live(UInt64, compiled: UInt64?)

    public init(liveCount: UInt64?, compiledCount: UInt64) {
        guard let liveCount else {
            self = .unavailable
            return
        }
        self = .live(liveCount, compiled: liveCount < compiledCount ? compiledCount : nil)
    }

    /// Tile value; nil renders as "—".
    public var value: UInt64? {
        if case .live(let count, _) = self { return count }
        return nil
    }

    public var caption: String? {
        switch self {
        case .unavailable:
            return "Tunnel not reachable"
        case .live(let count, let compiled?):
            return "\(count.formatted(.number.grouping(.automatic))) loaded of \(compiled.formatted(.number.grouping(.automatic)))"
        case .live(_, nil):
            return nil
        }
    }
}
