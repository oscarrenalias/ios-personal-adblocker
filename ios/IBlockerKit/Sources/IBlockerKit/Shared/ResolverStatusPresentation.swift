import Foundation

/// What the Dashboard status line (and the Settings DNS section header) shows
/// for the tunnel's resolver state. Pure logic: the UI maps `Tone` to a colour.
public struct ResolverStatusPresentation: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case positive
        case warning
        case critical
        case neutral
    }

    /// SF Symbol name.
    public let icon: String
    public let tone: Tone
    public let mainLine: String
    public let caption: String?
    public let showsDNSSettingsButton: Bool

    /// When the tunnel isn't connected the result is neutral with an empty
    /// `mainLine`; callers keep their existing text and icon for those states.
    public init(tunnelConnected: Bool, resolverStatus: ResolverStatus?) {
        guard tunnelConnected else {
            self.init(icon: "shield", tone: .neutral, mainLine: "", caption: nil, showsDNSSettingsButton: false)
            return
        }
        switch resolverStatus {
        case .alternative(let name, true):
            self.init(icon: "checkmark.shield.fill", tone: .positive,
                      mainLine: "Protected — encrypted DNS (\(name))", caption: nil, showsDNSSettingsButton: false)
        case .network:
            self.init(icon: "lock.open.fill", tone: .warning,
                      mainLine: "Protected — unencrypted DNS (Network DNS)",
                      caption: "Your network can see the sites you look up.", showsDNSSettingsButton: false)
        case .alternative(let name, false):
            self.init(icon: "lock.open.fill", tone: .warning,
                      mainLine: "Protected — unencrypted DNS (\(name))",
                      caption: "\(name) and your network can see the sites you look up.", showsDNSSettingsButton: false)
        case .fallingBack(let name):
            self.init(icon: "exclamationmark.triangle.fill", tone: .warning,
                      mainLine: "Protected — encrypted DNS unavailable",
                      caption: "\(name) can't be reached. Lookups are going unencrypted to your network's DNS until it's back.",
                      showsDNSSettingsButton: true)
        case .failing(let name):
            self.init(icon: "xmark.octagon.fill", tone: .critical,
                      mainLine: "DNS lookups are failing",
                      caption: "\(name) can't be reached and fallback is off.", showsDNSSettingsButton: true)
        case nil:
            self.init(icon: "checkmark.shield.fill", tone: .positive,
                      mainLine: "Protected — DNS filtering active", caption: nil, showsDNSSettingsButton: false)
        }
    }

    private init(icon: String, tone: Tone, mainLine: String, caption: String?, showsDNSSettingsButton: Bool) {
        self.icon = icon
        self.tone = tone
        self.mainLine = mainLine
        self.caption = caption
        self.showsDNSSettingsButton = showsDNSSettingsButton
    }
}
