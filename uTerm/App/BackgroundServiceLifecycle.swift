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
            return "没有打开「允许 CLI 按需启动」（设置 › 命令行与技能）"
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

/// 把 GUI 叫出来时，该让哪个窗口到最前。
///
/// 输入必须是 `NSApp.orderedWindows`：`NSApp.windows` 不保证顺序，实测欢迎窗常排第一。两个列表
/// 都留着已关闭和已隐藏的窗口，所以还要筛。有可见窗口就用最靠前的，全部最小化时才还原一个。
enum ReopenWindowPicker {
    static func pick(frontToBack windows: [NSWindow]) -> NSWindow? {
        let candidates = windows.filter { !($0 is NSPanel) }
        return candidates.first(where: \.isVisible) ?? candidates.first(where: \.isMiniaturized)
    }

    /// 后台唤起时窗口在视图出现之前就被藏起来了（`hideAll` 早于 SwiftUI 第一次布局），开窗入口因此一直没装上。
    /// 这时没有入口可调，只能把 SwiftUI 已经建好、藏着的窗口拿出来：它的视图一出现就会装上入口。
    static func pickHidden(_ windows: [NSWindow]) -> NSWindow? {
        windows.first { !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }
}

/// 转入后台时藏起来的窗口。`orderOut` 后的窗口和已关闭的窗口外观上分不开，只能自己记。
@MainActor
final class BackgroundedWindows: NSObject {
    private var windows: [NSWindow] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
    }

    func hideAll() {
        windows = NSApp.orderedWindows.filter(\.isVisible) + windows
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    func restore() {
        windows.reversed().forEach { $0.orderFront(nil) }
        windows = []
    }

    /// 后台里会话结束也会关窗口，这种窗口不能再放出来。
    @objc private func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as AnyObject? }
    }
}

@MainActor
final class UTermLifecycleDelegate: NSObject, NSApplicationDelegate {
    /// 开窗入口要从 Scene 环境取，由 `uTermApp` 装好后注入；此前 Dock 菜单没有自定义项。
    var dockMenu: DockMenuController?
    /// 欢迎窗关掉后它的视图就卸载了，所以入口不能挂在欢迎窗自己身上。
    static var openWelcome: (() -> Void)?
    /// 打开 `uterm://pair` 邀请链接（另一台 Mac 设置里拷出的）：交给「我的 Mac」窗口确认。由 `uTermApp` 装好；
    /// 冷启动时链接可能比它先到，先存着，装上时再交。
    static var openPairingLink: ((RemotePairingInvitation) -> Void)? {
        didSet {
            guard let openPairingLink, let pending = pendingPairingLink else { return }
            pendingPairingLink = nil
            openPairingLink(pending)
        }
    }
    private static var pendingPairingLink: RemotePairingInvitation?
    private static let backgroundedWindows = BackgroundedWindows()

    /// 在这里接住链接，SwiftUI 就不会为它另开一个窗口。只认配对邀请，别的 `uterm://` 链接不处理。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let invitation = RemotePairingInvitation(scanned: url.absoluteString) else { continue }
            Self.showGUI()
            if let open = Self.openPairingLink {
                open(invitation)
            } else {
                Self.pendingPairingLink = invitation
            }
        }
    }

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
        Self.backgroundedWindows.hideAll()
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
        // showGUI 处理完就返回 false：返回 true 时 AppKit 还会走默认流程，可能再还原一个窗口或多开一个。
        // 例外是一扇窗口都拿不出来（后台隐藏启动时 SwiftUI 不建初始窗口，开窗入口也就没装上）：这时让 AppKit
        // 走默认流程，SwiftUI 会开欢迎窗，它的视图出现时装上入口、接回终端。
        return Self.showGUI(handlingReopen: true) == .nothingToShow
    }

    /// 后台唤起的实例已经被要求露出界面（用户打开了 uTerm，或远控要用终端）。之后装好开窗入口时要接回终端。
    private(set) static var hasShownGUI = false

    enum GUIPresentation: Equatable {
        case shown
        /// 没有窗口可露出、也没有开窗入口。
        case nothingToShow
    }

    @discardableResult
    static func showGUI(handlingReopen: Bool = false) -> GUIPresentation {
        hasShownGUI = true
        LocalShellRestorer.shared.restoreIfNeeded()
        SSHSessionRestorer.shared.restoreIfNeeded()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        backgroundedWindows.restore()
        if let window = ReopenWindowPicker.pick(frontToBack: NSApp.orderedWindows) {
            window.makeKeyAndOrderFront(nil)
        } else if let openWelcome {
            openWelcome()
        } else if let hidden = ReopenWindowPicker.pickHidden(NSApp.windows) {
            hidden.makeKeyAndOrderFront(nil)
        } else {
            // 一扇窗口都没有：不在 reopen 里的话，请 LaunchServices 给自己发一次 reopen，走上面那条默认流程。
            if !handlingReopen { requestReopen() }
            return .nothingToShow
        }
        return .shown
    }

    /// 让系统按「用户又打开了 uTerm」给这个实例发一次 reopen（不会另起一个实例）。
    private static func requestReopen() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                AppLogger.info("请系统重新打开 uTerm 失败：\(error.localizedDescription)", category: "app")
            }
        }
    }

    static func moveToBackground() {
        backgroundedWindows.hideAll()
        NSApp.setActivationPolicy(.accessory)
    }

    static func quitCompletely() {
        NSApp.terminate(nil)
    }
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
