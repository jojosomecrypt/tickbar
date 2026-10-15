import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = Store()
    var bar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        store.start()
        bar = StatusBarController(store: store)
        if let dir = ProcessInfo.processInfo.environment["TICKBAR_SNAPSHOT"], let bar {
            Snapshot.run(store: store, bar: bar, dir: dir)
        }
    }

    // Show alerts even while the dropdown is open (the app counts as active then).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
