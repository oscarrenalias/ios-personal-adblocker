import Foundation

/// Decides whether a resolver-status change is worth a widget timeline
/// reload. The widget only shows the encryption state and resolver name, so
/// other status churn is ignored. Pure logic: the caller stores `published`
/// and resets it to nil when the widget's line is cleared.
public struct WidgetReloadGate: Equatable, Sendable {
    /// What the widget was last told about.
    public struct Published: Equatable, Sendable {
        public let state: WidgetEncryptionPresentation.State
        public let name: String?

        public init(state: WidgetEncryptionPresentation.State, name: String?) {
            self.state = state
            self.name = name
        }
    }

    public struct Decision: Equatable, Sendable {
        public let shouldReload: Bool
        /// The value the caller should remember as last published.
        public let published: Published
    }

    public static func evaluate(last: Published?, status: ResolverStatus?) -> Decision {
        let state = WidgetEncryptionPresentation(
            protectionActive: true, paused: false, resolverStatus: status).state
        let current = Published(state: state, name: name(of: status))
        return Decision(shouldReload: current != last, published: current)
    }

    private static func name(of status: ResolverStatus?) -> String? {
        switch status {
        case .alternative(let name, _), .fallingBack(let name), .failing(let name): return name
        case .network, nil: return nil
        }
    }
}
