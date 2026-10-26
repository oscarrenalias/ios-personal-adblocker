import WidgetKit
import AppIntents
import SwiftUI
import IBlockerKit

private let controlsLog = Log(category: "controls")

/// Control Center button that pauses ad blocking for a fixed number of minutes.
@available(iOS 18.0, *)
struct PauseControl {
    let kind: String
    let minutes: Int

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: PauseIntent(minutes: minutes)) {
                Label {
                    Text("Pause \(minutes) min")
                } icon: {
                    Image("pause.\(minutes)")
                }
            }
            .tint(.orange)
        }
        .displayName("Pause \(minutes) min")
        .description("Pause ad blocking for \(minutes) minutes.")
    }
}

@available(iOS 18.0, *)
struct Pause5Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        PauseControl(kind: WidgetKinds.pause5Control, minutes: 5).body
    }
}

@available(iOS 18.0, *)
struct Pause10Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        PauseControl(kind: WidgetKinds.pause10Control, minutes: 10).body
    }
}

@available(iOS 18.0, *)
struct Pause30Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        PauseControl(kind: WidgetKinds.pause30Control, minutes: 30).body
    }
}

@available(iOS 18.0, *)
struct Pause60Control: ControlWidget {
    var body: some ControlWidgetConfiguration {
        PauseControl(kind: WidgetKinds.pause60Control, minutes: 60).body
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
