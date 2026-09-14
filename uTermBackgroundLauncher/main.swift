import AppKit

final class BackgroundLauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginItems = Bundle.main.bundleURL.deletingLastPathComponent()
        let contents = loginItems.deletingLastPathComponent().deletingLastPathComponent()
        let mainApp = contents.deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--background", "--launch-source", "login-item"]
        NSWorkspace.shared.openApplication(at: mainApp, configuration: configuration) { _, _ in
            // 完成回调不保证在主线程，而 NSApp/terminate 是 MainActor 隔离的。
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = BackgroundLauncherDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
