import Foundation

/// 本机 shell 辅助程序（`uTermShellAgent.xpc`）的约定。
///
/// 主程序是沙盒 app，它直接派生的 shell 也关在沙盒里（读不到主目录、很多命令跑不了），
/// 所以由这个不带沙盒的内嵌 XPC 服务起登录 shell，再把伪终端主端的文件描述符经 XPC 交给主程序：
/// 之后的读写都是主程序直接对 fd，不经过辅助程序，只有起 shell、调尺寸、结束这几件低频的事走 XPC。
/// 为什么是内嵌 XPC 服务而不是 LaunchAgent：沙盒 app 用 `SMAppService` 注册不带沙盒的代理会被后台任务管理
/// 拒绝（macOS 14.2 起，报 Operation not permitted）；内嵌 XPC 服务由系统按需拉起，不用注册、不用用户授权。
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
    /// 起一个登录 shell（用户的默认 shell，`-zsh` 形式），工作目录是主目录。
    /// 成功回（伪终端主端，shell 进程号，nil）；失败回（nil，0，原因）。
    func openShell(columns: Int, rows: Int, reply: @escaping @Sendable (FileHandle?, Int32, String?) -> Void)
    /// 调伪终端尺寸（内核随即给前台进程组发 SIGWINCH）。
    func resize(pid: Int32, columns: Int, rows: Int)
    /// 结束一个 shell（给整个进程组发 SIGHUP，几秒内没退再 SIGKILL）。幂等。
    func terminate(pid: Int32)
}
