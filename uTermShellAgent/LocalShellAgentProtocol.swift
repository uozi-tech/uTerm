import Foundation

/// 本机 shell 辅助进程（`uTermShellAgent`）的约定。
///
/// 主程序是沙盒 app，它直接派生的 shell 也关在沙盒里（读不到主目录、很多命令跑不了），
/// 所以由这个不带沙盒的 LaunchAgent 起登录 shell，再把伪终端主端的文件描述符经 XPC 交给主程序：
/// 之后的读写都是主程序直接对 fd，不经过辅助进程，只有起 shell、调尺寸、结束这几件低频的事走 XPC。
///
/// 这个文件同时编进主程序与辅助进程（`uTermShellAgent` 文件夹对 uTerm target 只放行它）。
nonisolated enum LocalShellAgent {
    static let machServiceName = "com.uozi.uTerm.ShellAgent"
    /// `SMAppService.agent(plistName:)` 认的文件名，放在 `Contents/Library/LaunchAgents/`。
    static let plistName = "com.uozi.uTerm.ShellAgent.plist"
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
