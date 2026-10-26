import Foundation

/// Decides whether a foreground-only poll loop should run: only while at
/// least one view has registered interest AND the scene is active. Locking
/// the phone or backgrounding doesn't fire `onDisappear`, so visibility
/// alone isn't enough.
public struct PollingGate: Equatable, Sendable {
    public private(set) var pollers = 0
    public private(set) var isSceneActive: Bool

    public init(isSceneActive: Bool = true) {
        self.isSceneActive = isSceneActive
    }

    public var shouldRun: Bool { pollers > 0 && isSceneActive }

    public mutating func register() { pollers += 1 }

    public mutating func unregister() {
        guard pollers > 0 else { return }
        pollers -= 1
    }

    public mutating func setActive(_ active: Bool) { isSceneActive = active }
}
