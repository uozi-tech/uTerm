import Foundation

/// 本机 shell 辅助程序（`uTermShellAgent.xpc`）的约定。
///
/// 主程序是沙盒 app，它直接派生的 shell 也关在沙盒里（读不到主目录、很多命令跑不了），所以由这个不带沙盒的
/// 内嵌 XPC 服务拉起 `uterm-holder`，由 holder 持有 PTY 并跑登录 shell。holder 脱离 XPC 服务独立运行：
/// uTerm 退出、崩溃、被替换，shell 都不受影响，下次打开接回来。
///
/// 这个服务本身随 uTerm 生灭，只做两件事：拉起 holder；替沙盒里的主程序连上 holder 的 socket，把 fd 交过去
///（沙盒 app 连不了容器外的 Unix socket）。之后主程序直接和 holder 说话，线上格式见 `HolderProtocol`。
///
/// 为什么不用 LaunchAgent：沙盒 app 用 `SMAppService` 注册不带沙盒的代理会被后台任务管理拒绝
///（macOS 14.2 起，报 Operation not permitted）。
///
/// 这个文件同时编进主程序与辅助程序（`uTermShellAgent` 文件夹对 uTerm target 只放行它）。
nonisolated enum LocalShellAgent {
    /// XPC 服务名 = 辅助程序的 bundle id（`NSXPCConnection(serviceName:)` 用）。
    static let serviceName = AppIdentity.shellAgent
    /// 只接受同一团队签名的 uTerm 主程序来连：起的是这个用户的登录 shell，不能谁都能要。远控进程（`uTermRemoteHost`）包里
    /// 也嵌了一份这个服务，替它执行远程文件请求，所以也放行它。
    static let clientRequirement =
        CodeSigningTeam.requirement(identifiers: [AppIdentity.app, AppIdentity.remoteHost])
}

@objc nonisolated protocol LocalShellAgentProtocol {
    /// 探活：设置页据此显示「辅助进程正常」。回辅助进程的版本号。
    func ping(reply: @escaping @Sendable (String) -> Void)
    /// 连上会话 `id`；还没有就新起一个（用户的登录 shell，工作目录是 `directory`，nil = 主目录）。成功回（到 holder 的连接，nil）。
    /// `namespace` 隔开互不相干的 uTerm（正式版一份，每个 Debug 构建路径一份）。
    /// `ownsResponsibility`：新会话自己当责任进程，见 `LocalShellNetworkPolicy`。接回已有会话时不起作用。
    func openSession(namespace: String, id: String, directory: String?, columns: Int, rows: Int, ownsResponsibility: Bool,
                     reply: @escaping @Sendable (FileHandle?, String?) -> Void)
    /// SSH 会话版的 `openSession`：`id` 已有会话就只回（到 holder 的连接，nil，nil）；否则起一个跑 `uterm-ssh` 的 holder，
    /// 回（到 holder 的连接，控制通道，nil）。App 经控制通道把连接参数交给 `uterm-ssh`，见 `SSHBridgeMessage`。
    func openSSHSession(namespace: String, id: String, columns: Int, rows: Int,
                        reply: @escaping @Sendable (FileHandle?, FileHandle?, String?) -> Void)
    /// 只连已有的会话，没有就报错。
    func connectSession(namespace: String, id: String, reply: @escaping @Sendable (FileHandle?, String?) -> Void)
    /// 列出活着的会话 id。连不上的（holder 已经不在）顺手清掉 socket 文件。
    func listSessions(namespace: String, reply: @escaping @Sendable ([String]) -> Void)
    /// 远控文件服务：一条打包好的请求进、一条打包好的应答出（格式见 `RemoteFileWire`，执行在 `RemoteFileService`）。
    /// 主程序在沙盒里读不到主目录，文件操作和跑命令都得在这边做。该不该放行由主程序在转发之前判断。
    func fileRequest(_ payload: Data, reply: @escaping @Sendable (Data) -> Void)
    /// 同上，但只放行落在 `scope`（JSON 编码的 `RemoteFileScope`）里的请求：主控端把几个文件夹共享给被控的 Mac 时用。
    /// 路径要解析掉符号链接才能判断在不在范围里，沙盒里的主程序做不了，所以检查也在这边做。
    func scopedFileRequest(_ payload: Data, scope: Data, reply: @escaping @Sendable (Data) -> Void)
    /// 用户在本机终端里 ⌘ 点了一个路径（绝对路径）：文件用系统默认的 App 打开，目录与不该直接打开的东西在 Finder 里显示
    /// （规则见 `LocalPathOpenPolicy`）。沙盒里的主程序看不到主目录，打开也得在这边做。回 false = 不存在或打不开。
    func openLocalPath(_ path: String, reply: @escaping @Sendable (Bool) -> Void)
}

/// 本机终端里 ⌘ 点一个路径怎么处理。终端里的文字谁都能写（`cat` 一个下载来的文件、程序的输出），点一下不能变成
/// 「运行了什么」：可执行文件、App 与安装包、脚本、快捷方式一类只在 Finder 里显示，不打开。
nonisolated enum LocalPathOpenPolicy {
    enum Action: Equatable {
        /// 交给系统默认的 App 打开（`open <路径>`）。
        case open
        /// 在 Finder 里显示（`open -R <路径>`）。
        case reveal
    }

    /// 打开就会运行点什么、或者改系统设置的扩展名（小写）。
    static let revealOnlyExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "workflow", "action", "scpt", "scptd", "applescript",
        "pkg", "mpkg", "dmg", "jar", "webloc", "inetloc", "fileloc", "url", "prefpane", "kext", "mobileconfig",
        "shortcut", "service", "plugin", "bundle", "framework", "appex", "xpc", "systemextension", "dext",
        "saver", "qlgenerator", "mdimporter", "osax",
    ]

    /// `isDirectory`：是目录（App 也是目录）；`isExecutable`：普通文件带任意一个执行位。
    static func action(path: String, isDirectory: Bool, isExecutable: Bool) -> Action {
        if isDirectory || isExecutable { return .reveal }
        let ext = (path as NSString).pathExtension.lowercased()
        return revealOnlyExtensions.contains(ext) ? .reveal : .open
    }

    /// 交给 `/usr/bin/open` 的参数。路径是绝对路径（以 `/` 开头），不会被当成选项。
    static func openArguments(path: String, action: Action) -> [String] {
        switch action {
        case .open: return [path]
        case .reveal: return ["-R", path]
        }
    }
}
