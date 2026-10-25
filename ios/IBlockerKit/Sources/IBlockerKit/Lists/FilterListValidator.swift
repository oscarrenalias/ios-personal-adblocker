import Foundation

/// Sanity-checks a downloaded filter list before it replaces the stored copy.
/// Pure logic: no I/O and no logging (the updater logs the outcome).
public enum FilterListValidator {

    public enum Outcome: Sendable, Equatable {
        case accept(entryCount: Int)
        case reject(reason: String)
    }

    /// How much of the download is inspected for an HTML page signature.
    static let htmlSniffLength = 1024
    /// Reject when skipped lines exceed this fraction of non-comment lines.
    static let maxSkippedFraction = 0.5
    /// Reject when the new entry count falls below this fraction of the previous one.
    static let minCountFractionOfPrevious = 0.5

    public static func validate(_ text: String, previousCount: Int?) -> Outcome {
        let head = String(text.prefix(htmlSniffLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.contains("<html") {
            return .reject(reason: "Server returned a web page, not a list")
        }

        let parsed = FilterListParser.parse(text)
        let count = parsed.blockDomains.count
        if count == 0 {
            return .reject(reason: "Download contained no rules")
        }

        let ruleLines = parsed.totalLines - parsed.commentLines
        if Double(parsed.skippedLines) > maxSkippedFraction * Double(ruleLines) {
            return .reject(reason: "Most lines couldn't be read (\(parsed.skippedLines) of \(ruleLines))")
        }

        if let previous = previousCount, previous > 0,
           Double(count) < minCountFractionOfPrevious * Double(previous) {
            return .reject(reason: "Has \(count) rules, was \(previous) — kept the previous version")
        }

        return .accept(entryCount: count)
    }
}
