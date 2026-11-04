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
    static let serviceName = "com.uozi.uTerm.ShellAgent"
    /// 只接受同一团队签名的 uTerm 主程序来连：起的是这个用户的登录 shell，不能谁都能要。
    static let clientRequirement =
        "anchor apple generic and identifier \"com.uozi.uTerm\" and certificate leaf[subject.OU] = \"ABCDE12345\""
}

@objc nonisolated protocol LocalShellAgentProtocol {
    /// 探活：设置页据此显示「辅助进程正常」。回辅助进程的版本号。
    func ping(reply: @escaping @Sendable (String) -> Void)
    /// 连上会话 `id`；还没有就新起一个（用户的登录 shell，工作目录是主目录）。成功回（到 holder 的连接，nil）。
    /// `namespace` 隔开互不相干的 uTerm（正式版一份，每个 Debug 构建路径一份）。
    func openSession(namespace: String, id: String, columns: Int, rows: Int,
                     reply: @escaping @Sendable (FileHandle?, String?) -> Void)
    /// 只连已有的会话，没有就报错。
    func connectSession(namespace: String, id: String, reply: @escaping @Sendable (FileHandle?, String?) -> Void)
    /// 列出活着的会话 id。连不上的（holder 已经不在）顺手清掉 socket 文件。
    func listSessions(namespace: String, reply: @escaping @Sendable ([String]) -> Void)
}
