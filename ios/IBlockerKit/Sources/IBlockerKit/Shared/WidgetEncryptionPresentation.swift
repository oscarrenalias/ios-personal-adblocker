import Foundation

/// The DNS-encryption line the status widget shows under its header. Pure
/// logic: the widget maps `Tone` to a colour (green, orange, red).
public struct WidgetEncryptionPresentation: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// Protection is off or paused: no line.
        case hidden
        case encrypted
        case unencrypted
        case fallback
        case failing
        /// Protection is active but the tunnel hasn't published a status: no line.
        case unknown

        /// Stable name for logs.
        public var logName: String { rawValue }
    }

    public enum Tone: Equatable, Sendable {
        case positive
        case warning
        case critical
    }

    public let state: State
    /// SF Symbol name; nil when the line is hidden.
    public let symbol: String?
    /// Line text; nil when the line is hidden.
    public let text: String?
    public let tone: Tone?

    public init(protectionActive: Bool, paused: Bool, resolverStatus: ResolverStatus?) {
        guard protectionActive, !paused else {
            self.init(state: .hidden, symbol: nil, text: nil, tone: nil)
            return
        }
        switch resolverStatus {
        case .alternative(let name, true):
            self.init(state: .encrypted, symbol: "lock.fill", text: "Encrypted · \(name)", tone: .positive)
        case .network:
            self.init(state: .unencrypted, symbol: "lock.open.fill", text: "Unencrypted DNS", tone: .warning)
        case .alternative(let name, false):
            self.init(state: .unencrypted, symbol: "lock.open.fill", text: "Unencrypted · \(name)", tone: .warning)
        case .fallingBack:
            self.init(state: .fallback, symbol: "exclamationmark.triangle.fill",
                      text: "Encrypted DNS unavailable", tone: .warning)
        case .failing:
            self.init(state: .failing, symbol: "xmark.octagon.fill", text: "DNS failing", tone: .critical)
        case nil:
            self.init(state: .unknown, symbol: nil, text: nil, tone: nil)
        }
    }

    private init(state: State, symbol: String?, text: String?, tone: Tone?) {
        self.state = state
        self.symbol = symbol
        self.text = text
        self.tone = tone
    }
}
