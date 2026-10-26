import WidgetKit
import AppIntents
import SwiftUI
import IBlockerKit

private let controlsLog = Log(category: "controls")

@available(iOS 18.0, *)
struct Pause5Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.pause5Control) {
            ControlWidgetButton(action: PauseIntent(minutes: 5)) {
                Label("Pause 5 min", systemImage: "5.circle")
            }
        }
        .displayName("Pause 5 min")
        .description("Pause ad blocking for 5 minutes.")
    }
}

@available(iOS 18.0, *)
struct Pause10Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.pause10Control) {
            ControlWidgetButton(action: PauseIntent(minutes: 10)) {
                Label("Pause 10 min", systemImage: "10.circle")
            }
        }
        .displayName("Pause 10 min")
        .description("Pause ad blocking for 10 minutes.")
    }
}

@available(iOS 18.0, *)
struct Pause30Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.pause30Control) {
            ControlWidgetButton(action: PauseIntent(minutes: 30)) {
                Label("Pause 30 min", systemImage: "30.circle")
            }
        }
        .displayName("Pause 30 min")
        .description("Pause ad blocking for 30 minutes.")
    }
}

/// Pauses blocking for `minutes`. Writes `SharedSettings.pausedUntil`; the
/// tunnel re-reads it periodically, so no IPC is needed.
struct PauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Ad Blocking"
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Minutes")
    var minutes: Int

    init() { minutes = 5 }
    init(minutes: Int) { self.minutes = minutes }

    func perform() async throws -> some IntentResult {
        let label = "pause button \(minutes) min"
        guard let settings = WidgetEnvironment.settings else {
            controlsLog.error("\(label): shared settings unavailable")
            return .result()
        }
        let result = PauseDeadline.resolve(
            durationMinutes: minutes,
            now: Date(),
            protectionActive: settings.protectionActive,
            currentPausedUntil: settings.pausedUntil
        )
        guard case let .pause(deadline, replaced) = result else {
            controlsLog.info("\(label) ignored: protection off")
            return .result()
        }
        if replaced, let old = settings.pausedUntil {
            let oldTime = old.formatted(date: .omitted, time: .shortened)
            controlsLog.info("\(label): replaced pause ending \(oldTime)")
        }
        settings.pausedUntil = deadline
        let newTime = deadline.formatted(date: .omitted, time: .shortened)
        controlsLog.notice("\(label): paused until \(newTime)")

        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadControls(ofKind: WidgetKinds.protectionControl)
        return .result()
    }
}
