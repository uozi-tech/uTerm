import AppKit
import Foundation
import SwiftUI
import SwiftData

enum BackgroundLaunchMode {
    enum Presentation: Equatable { case background, foreground }

    static func presentation(arguments: [String]) -> Presentation {
        arguments.contains("--background") ? .background : .foreground
    }

    static func shouldStartHidden(arguments: [String]) -> Bool {
        presentation(arguments: arguments) == .background
    }

    static let reopenPresentation: Presentation = .foreground
    static var isRunningInTestHost: Bool { TestHostEnvironment.isActive }

    static let requestedByCLI = shouldStartHidden(arguments: ProcessInfo.processInfo.arguments)
    static var shouldStartHidden: Bool { requestedByCLI }

    /// `utermctl` 按需唤起时传 `--launch-source cli`（登录项传 `login-item`）。
    static let cliLaunchSource = "cli"

    static func launchSource(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--launch-source"),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    /// CLI 按需唤起由 app 自己把关，返回拒绝原因；nil 表示放行。
    ///
    /// 客户端本来会先读设置再决定唤不唤起，但 macOS 27 起没给完全磁盘访问权限的进程读不了
    /// 沙盒容器里的偏好 plist（`EPERM`）。读不到时客户端照样请求启动，由这里按用户设置决定
    /// 去留：「允许 CLI 按需启动」与「启用命令行接口」缺一不可，否则进程立刻退出，客户端靠
    /// `open -W` 看到它退出后报错。非 CLI 来源（手动打开、登录项）一律放行。
    static func cliLaunchRefusal(arguments: [String], defaults: UserDefaults) -> String? {
        guard launchSource(arguments: arguments) == cliLaunchSource else { return nil }
        guard defaults.object(forKey: BackgroundServiceSettings.Keys.allowOnDemandLaunch) as? Bool == true else {
            return "设置中没有允许 CLI 按需启动"
        }
        guard defaults.object(forKey: ControlSettings.Keys.enabled) as? Bool == true else {
            return "命令行接口未启用"
        }
        return nil
    }
}

@main
enum UTermEntryPoint {
    static func main() {
        if let refusal = BackgroundLaunchMode.cliLaunchRefusal(
            arguments: ProcessInfo.processInfo.arguments, defaults: .standard) {
            AppLogger.info("拒绝 CLI 按需启动：\(refusal)", category: "control")
            exit(0)
        }
        uTermApp.main()
    }
}

@MainActor
enum LaunchForwardingBootstrap {
    static func start(
        modelContainer: ModelContainer,
        model: GlobalForwardingModel,
        coordinator: ForwardingCoordinator,
        relay: HostKeyChallengeRelay
    ) {
        let context = modelContainer.mainContext
        let launchRules = ForwardingRuleStore(context: context).allRules().filter(\.launchAtAppStart)
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]))) ?? []
        let items: [GlobalForwardingModel.LaunchItem] = profiles.flatMap { profile in
            launchRules
                .filter { $0.serverID == profile.id }
                .map { GlobalForwardingModel.LaunchItem(rule: $0.snapshot, server: profile) }
        }
        model.autoTriggerIfNeeded(
            items: items,
            coordinator: coordinator,
            relay: relay,
            container: context.container
        )
    }
}

@MainActor
final class UTermLifecycleDelegate: NSObject, NSApplicationDelegate {
    /// 开窗入口要从 Scene 环境取，由 `uTermApp` 装好后注入；此前 Dock 菜单没有自定义项。
    var dockMenu: DockMenuController?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu?.makeMenu()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if BackgroundLaunchMode.shouldStartHidden {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BackgroundLaunchMode.shouldStartHidden else { return }
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    /// 退出前依次问：运行中的终端怎么办（`TerminalQuitPolicy`）；「打开」出去、还没传回服务器的文件
    ///（`ExternalEditCloseGuard`）。任何一步取消都不退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard TerminalQuitPolicy.shared.confirmQuit() else { return .terminateCancel }
        let reply = ExternalEditCloseGuard.shouldTerminate(sender)
        if reply == .terminateCancel { TerminalQuitPolicy.shared.quitCancelled() }
        return reply
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        precondition(BackgroundLaunchMode.reopenPresentation == .foreground)
        Self.showGUI()
        return true
    }

    static func showGUI() {
        LocalShellRestorer.shared.restoreIfNeeded()
        SSHSessionRestorer.shared.restoreIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.windows.filter { !($0 is NSPanel) }
        if let window = windows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .showWelcomeWindow, object: nil)
        }
    }

    static func moveToBackground() {
        NSApp.windows.forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)
    }

    static func quitCompletely() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let showWelcomeWindow = Notification.Name("uterm.showWelcomeWindow")
}

struct BackgroundLifecycleCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("转入后台") { UTermLifecycleDelegate.moveToBackground() }
            Divider()
            Button("完全退出 uTerm") { UTermLifecycleDelegate.quitCompletely() }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}
