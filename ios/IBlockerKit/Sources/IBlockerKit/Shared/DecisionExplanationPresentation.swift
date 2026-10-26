import Foundation

/// Text for the query-log detail sheet and the "Test a domain" screen.
/// Pure logic: callers pass a log record or a matcher explanation plus the
/// current `FilterListState` used to resolve source numbers to list names.
public struct DecisionExplanationPresentation: Equatable, Sendable {
    public static let removedListName = "a removed list"
    public static let unknownListName = "an unknown list"
    public static let notRecordedText = "Details not recorded for this entry"

    /// The "Why" line.
    public let why: String
    /// Second line for allowed/failed lookups: cache or resolver route.
    public let routeLine: String?

    public init(why: String, routeLine: String?) {
        self.why = why
        self.routeLine = routeLine
    }

    // MARK: - Query log record

    /// Values of the record's `source` byte (byte 11).
    private enum RecordSource: UInt8 {
        case notRecorded = 0, noRule, userAllowlist, userDenylist, builtIn
        case listException, list, paused
    }

    public init(record: QueryLogRecord, state: FilterListState) {
        guard let details = record.details else {
            self.init(why: Self.notRecordedText, routeLine: nil)
            return
        }
        let routeLine = Self.routeLine(cacheHit: details.cacheHit, route: details.route)
        let kind = RecordSource(rawValue: record.source) ?? .notRecorded
        let suffix = Self.suffix(of: record.domain, labels: Int(details.matchedLabels))
        let listName = Self.listName(number: details.sourceNumber, state: state)
        let bundled = Self.isBundled(number: details.sourceNumber, state: state)

        switch record.verdict {
        case .failed:
            self.init(why: "Lookup failed", routeLine: routeLine)
        case .blocked:
            switch kind {
            case .userDenylist:
                self.init(why: "Blocked by your denylist", routeLine: nil)
            case .builtIn:
                self.init(why: "Blocked by built-in rules", routeLine: nil)
            case .list where bundled:
                self.init(why: "Blocked by built-in rules", routeLine: nil)
            case .list:
                self.init(why: "Blocked by \(Self.phrase(suffix, in: listName))", routeLine: nil)
            default:
                self.init(why: Self.notRecordedText, routeLine: nil)
            }
        case .allowed:
            switch kind {
            case .userAllowlist:
                self.init(why: "Allowed by your allowlist", routeLine: routeLine)
            case .listException:
                let target = suffix.map { "\($0) " } ?? ""
                self.init(why: "Allowed by \(target)(exception in \(Self.exceptionListName(number: details.sourceNumber, state: state)))",
                          routeLine: routeLine)
            case .noRule:
                self.init(why: "No rule matched", routeLine: routeLine)
            case .paused:
                self.init(why: "Allowed: blocking was paused", routeLine: routeLine)
            default:
                self.init(why: Self.notRecordedText, routeLine: nil)
            }
        }
    }

    // MARK: - Matcher explanation (Test a domain)

    public init(explanation: DomainMatcher.Explanation, state: FilterListState) {
        guard let match = explanation.decidingMatch else {
            self.init(why: "No rule matched", routeLine: nil)
            return
        }
        let folded = Self.folded(match.source, state: state)
        let suffix = match.matchedSuffix
        switch folded {
        case .userAllowlist:
            self.init(why: "Allowed by your allowlist", routeLine: nil)
        case .userDenylist:
            self.init(why: "Blocked by your denylist", routeLine: nil)
        case .builtIn:
            self.init(why: "Blocked by built-in rules", routeLine: nil)
        case .listException(let number):
            self.init(why: "Allowed by \(suffix) (exception in \(Self.exceptionListName(number: number, state: state)))",
                      routeLine: nil)
        case .list(let number):
            self.init(why: "Blocked by \(Self.phrase(suffix, in: Self.listName(number: number, state: state)))",
                      routeLine: nil)
        }
    }

    /// One row of the "every match" list on the test screen.
    public struct MatchLine: Equatable, Sendable {
        public let text: String
        public let isDeciding: Bool
        public let isOverridden: Bool
    }

    /// Lines for `DomainMatcher.allMatches`, in precedence order. Matches from
    /// bundled sources are folded into the built-in match (one line), and every
    /// match other than the deciding one is marked as overridden.
    public static func matchLines(deciding: DomainMatcher.Match?,
                                  all: [DomainMatcher.Match],
                                  state: FilterListState) -> [MatchLine] {
        let decidingFolded = deciding.map { Match(source: folded($0.source, state: state), suffix: $0.matchedSuffix) }
        let overrider = deciding.map { overrideReason(folded($0.source, state: state), state: state) }

        var seen: [Match] = []
        var lines: [MatchLine] = []
        for raw in all {
            let match = Match(source: folded(raw.source, state: state), suffix: raw.matchedSuffix)
            // Folding can produce duplicates (e.g. built-in floor plus a bundled list).
            if seen.contains(match) { continue }
            seen.append(match)

            if match == decidingFolded {
                lines.append(MatchLine(text: "\(describe(match, state: state))", isDeciding: true, isOverridden: false))
            } else {
                let text = "also \(describe(match, state: state))" + (overrider.map { " (overridden by \($0))" } ?? "")
                lines.append(MatchLine(text: text, isDeciding: false, isOverridden: true))
            }
        }
        return lines
    }

    // MARK: - Helpers

    private struct Match: Equatable {
        let source: DomainMatcher.MatchSource
        let suffix: String
    }

    private static func describe(_ match: Match, state: FilterListState) -> String {
        switch match.source {
        case .userAllowlist: return "\(match.suffix) in your allowlist"
        case .userDenylist: return "\(match.suffix) in your denylist"
        case .builtIn: return "\(match.suffix) in built-in rules"
        case .listException(let n):
            return "\(match.suffix) listed as an exception in \(exceptionListName(number: n, state: state))"
        case .list(let n): return "\(match.suffix) listed in \(listName(number: n, state: state))"
        }
    }

    private static func overrideReason(_ source: DomainMatcher.MatchSource, state: FilterListState) -> String {
        switch source {
        case .userAllowlist: return "your allowlist"
        case .userDenylist: return "your denylist"
        case .builtIn: return "built-in rules"
        case .listException(let n): return "an exception in \(exceptionListName(number: n, state: state))"
        case .list(let n): return listName(number: n, state: state)
        }
    }

    /// Bundled-source list matches count as built-in rules.
    private static func folded(_ source: DomainMatcher.MatchSource, state: FilterListState) -> DomainMatcher.MatchSource {
        if case .list(let n) = source, isBundled(number: n, state: state) { return .builtIn }
        return source
    }

    private static func sourceID(number: UInt8, state: FilterListState) -> String? {
        guard number != 0, let numbers = state.sourceNumbers else { return nil }
        return numbers.first(where: { $0.value == number })?.key
    }

    private static func isBundled(number: UInt8, state: FilterListState) -> Bool {
        guard let id = sourceID(number: number, state: state) else { return false }
        return id == SeedRules.sourceID || id == SeedRules.relaySourceID
    }

    private static func listName(number: UInt8, state: FilterListState) -> String {
        if number == 0 { return unknownListName }
        guard let id = sourceID(number: number, state: state),
              let source = state.sources.first(where: { $0.id == id })
        else { return removedListName }
        return source.name
    }

    /// Bundled lists can carry exceptions too; they read as built-in.
    private static func exceptionListName(number: UInt8, state: FilterListState) -> String {
        isBundled(number: number, state: state) ? "built-in rules" : listName(number: number, state: state)
    }

    private static func phrase(_ suffix: String?, in listName: String) -> String {
        suffix.map { "\($0) in \(listName)" } ?? listName
    }

    /// The domain's last `labels` labels; nil when none was recorded.
    private static func suffix(of domain: String, labels: Int) -> String? {
        guard labels > 0 else { return nil }
        let parts = domain.split(separator: ".", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }
        return parts.suffix(labels).joined(separator: ".")
    }

    private static func routeLine(cacheHit: Bool, route: LogRoute) -> String {
        if cacheHit { return "Answered from cache" }
        switch route {
        case .alternative: return "Encrypted DNS"
        case .network: return "Network DNS"
        case .networkOnlyName: return "Network DNS (name always sent to your network)"
        case .fallback: return "Network DNS (encrypted resolver unavailable)"
        case .local: return "Answered locally (.local name)"
        }
    }
}
