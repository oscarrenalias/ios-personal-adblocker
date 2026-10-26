import Foundation

/// Stable identifiers shared between the widget extension and the app
/// (which asks WidgetKit/Control Center to reload them).
public enum WidgetKinds {
    public static let statusWidget = "net.renalias.adblocker.widget.status"
    public static let protectionControl = "net.renalias.adblocker.control.protection"
    public static let pause5Control = "net.renalias.adblocker.control.pause5"
    public static let pause10Control = "net.renalias.adblocker.control.pause10"
    public static let pause30Control = "net.renalias.adblocker.control.pause30"
    public static let pause60Control = "net.renalias.adblocker.control.pause60"
}
