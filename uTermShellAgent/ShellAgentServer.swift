import Darwin
import Foundation
import os

/// 辅助程序本体：收连接（只认 uTerm 主程序）、起登录 shell、调尺寸、结束与收尸。
///
/// 所有状态只在 `queue` 上读写。每个 shell 记着是哪条连接开的：主程序那条连接断了（退出、崩溃），
/// 它开的 shell 一并结束，不留没人管的登录会话。作为内嵌 XPC 服务时生命周期归系统管
///（`exitsWhenIdle: false`）；`exitsWhenIdle` 只给独立运行的形态用。
nonisolated final class ShellAgentServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let version = "1"
    private static let idleExitSeconds = 60
    private static let killGraceSeconds = 3

    private let queue = DispatchQueue(label: "com.uozi.uTerm.ShellAgent")
    private let log = Logger(subsystem: "com.uozi.uTerm", category: "shell-agent")

    // 以下只在 queue 上。
    private var shells: [pid_t: Shell] = [:]
    private var owners: Set<ObjectIdentifier> = []
    private var idleTimer: DispatchSourceTimer?

    private final class Shell {
        let pid: pid_t
        /// 辅助进程自己留的那份主端：调尺寸用。给主程序的是 dup 出去的另一份。
        let master: Int32
        let owner: ObjectIdentifier
        var exitSource: DispatchSourceProcess?

        init(pid: pid_t, master: Int32, owner: ObjectIdentifier) {
            self.pid = pid
            self.master = master
            self.owner = owner
        }
    }

    /// 来连的进程要满足的签名条件。nil 只给进程内的匿名监听器用（探针）：那时双方是同一个进程。
    private let clientRequirement: String?
    private let exitsWhenIdle: Bool

    init(clientRequirement: String? = LocalShellAgent.clientRequirement, exitsWhenIdle: Bool = true) {
        self.clientRequirement = clientRequirement
        self.exitsWhenIdle = exitsWhenIdle
        super.init()
        queue.async { self.scheduleIdleExitIfNeeded() }
    }

    // MARK: - 连接

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let clientRequirement { connection.setCodeSigningRequirement(clientRequirement) }
        connection.exportedInterface = NSXPCInterface(with: LocalShellAgentProtocol.self)
        let owner = ObjectIdentifier(connection)
        connection.exportedObject = ShellAgentSession(server: self, owner: owner)
        let ended: @Sendable () -> Void = { [weak self] in self?.connectionEnded(owner) }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        queue.async {
            self.owners.insert(owner)
            self.idleTimer?.cancel()
            self.idleTimer = nil
        }
        connection.resume()
        return true
    }

    private func connectionEnded(_ owner: ObjectIdentifier) {
        queue.async {
            // 中断与失效可能各来一次，只处理第一次。
            guard self.owners.remove(owner) != nil else { return }
            for shell in self.shells.values where shell.owner == owner {
                self.hangUp(shell)
            }
            self.scheduleIdleExitIfNeeded()
        }
    }

    // MARK: - shell

    func openShell(columns: Int, rows: Int, owner: ObjectIdentifier) -> (FileHandle?, Int32, String?) {
        queue.sync {
            var size = winsize(ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, columns)),
                               ws_xpixel: 0, ws_ypixel: 0)
            let shellPath = Self.loginShell()
            let argv0 = "-" + (shellPath as NSString).lastPathComponent
            let home = NSHomeDirectory()
            guard let (pid, master) = Self.forkPTY(executable: shellPath, args: [argv0], env: Self.environment(shell: shellPath),
                                                   directory: home, size: &size) else {
                let reason = String(cString: strerror(errno))
                log.error("起 shell 失败：\(reason, privacy: .public)")
                return (nil, 0, "无法创建伪终端：\(reason)")
            }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            let handed = dup(master)
            guard handed >= 0 else {
                kill(-pid, SIGKILL)
                close(master)
                return (nil, 0, "无法复制伪终端：\(String(cString: strerror(errno)))")
            }
            _ = fcntl(handed, F_SETFD, FD_CLOEXEC)
            let shell = Shell(pid: pid, master: master, owner: owner)
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.reap(pid) }
            shell.exitSource = source
            source.resume()
            shells[pid] = shell
            idleTimer?.cancel()
            idleTimer = nil
            log.info("起 shell \(shellPath, privacy: .public) pid=\(pid) \(columns)×\(rows)")
            // XPC 编码这条回复时会 dup 一份，回复发出后 FileHandle 释放、关掉辅助进程这份。
            return (FileHandle(fileDescriptor: handed, closeOnDealloc: true), pid, nil)
        }
    }

    func resize(pid: Int32, columns: Int, rows: Int, owner: ObjectIdentifier) {
        queue.async {
            guard let shell = self.shells[pid], shell.owner == owner else { return }
            var size = winsize(ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, columns)),
                               ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(shell.master, TIOCSWINSZ, &size)
        }
    }

    func terminate(pid: Int32, owner: ObjectIdentifier) {
        queue.async {
            guard let shell = self.shells[pid], shell.owner == owner else { return }
            self.hangUp(shell)
        }
    }

    /// SIGHUP 整个进程组（shell 是会话首进程，进程组号 = pid），宽限几秒还在就 SIGKILL。
    private func hangUp(_ shell: Shell) {
        kill(-shell.pid, SIGHUP)
        kill(shell.pid, SIGHUP)
        let pid = shell.pid
        queue.asyncAfter(deadline: .now() + .seconds(Self.killGraceSeconds)) {
            guard self.shells[pid] != nil else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func reap(_ pid: pid_t) {
        var status: Int32 = 0
        _ = waitpid(pid, &status, WNOHANG)
        guard let shell = shells.removeValue(forKey: pid) else { return }
        shell.exitSource?.cancel()
        close(shell.master)
        log.info("shell 结束 pid=\(pid)")
        scheduleIdleExitIfNeeded()
    }

    private func scheduleIdleExitIfNeeded() {
        guard exitsWhenIdle, owners.isEmpty, shells.isEmpty, idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Self.idleExitSeconds))
        timer.setEventHandler { [weak self] in
            guard let self, self.owners.isEmpty, self.shells.isEmpty else { return }
            self.log.info("空闲退出")
            exit(0)
        }
        idleTimer = timer
        timer.resume()
    }

    // MARK: - 进程

    /// 用户的登录 shell（目录服务里的 `UserShell`），取不到就用 zsh。
    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// 在 launchd 给的环境上补终端相关的几项；PATH 等由登录 shell 自己读 `/etc/zprofile`（path_helper）补全。
    static func environment(shell: String) -> [String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("XPC_") && !key.hasPrefix("__CF")
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "uTerm"
        env["SHELL"] = shell
        if env["LANG"] == nil { env["LANG"] = posixLocale() }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// 「终端」app 的做法：按系统语言与地区拼 `zh_CN.UTF-8` 这种形式；拼不出来就用 en_US.UTF-8。
    static func posixLocale() -> String {
        let locale = Locale.current
        guard let language = locale.language.languageCode?.identifier,
              let region = locale.region?.identifier else { return "en_US.UTF-8" }
        return "\(language)_\(region).UTF-8"
    }

    /// `forkpty` + `execve`。参数在 fork 之前全部备好：子进程里只调 async-signal-safe 的函数。
    static func forkPTY(executable: String, args: [String], env: [String], directory: String,
                        size: inout winsize) -> (pid_t, Int32)? {
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup($0) } + [nil]
        let cExecutable = strdup(executable)
        let cDirectory = strdup(directory)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cExecutable)
            free(cDirectory)
        }
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 { return nil }
        if pid == 0 {
            _ = chdir(cDirectory)
            _ = execve(cExecutable, cArgs, cEnv)
            _exit(127)
        }
        return (pid, master)
    }
}

/// 每条连接导出的对象：把调用连同「是哪条连接」交给服务端，服务端据此只允许连接动自己开的 shell。
nonisolated final class ShellAgentSession: NSObject, LocalShellAgentProtocol, @unchecked Sendable {
    private let server: ShellAgentServer
    private let owner: ObjectIdentifier

    init(server: ShellAgentServer, owner: ObjectIdentifier) {
        self.server = server
        self.owner = owner
    }

    func ping(reply: @escaping @Sendable (String) -> Void) {
        reply(ShellAgentServer.version)
    }

    func openShell(columns: Int, rows: Int, reply: @escaping @Sendable (FileHandle?, Int32, String?) -> Void) {
        let (handle, pid, error) = server.openShell(columns: columns, rows: rows, owner: owner)
        reply(handle, pid, error)
    }

    func resize(pid: Int32, columns: Int, rows: Int) {
        server.resize(pid: pid, columns: columns, rows: rows, owner: owner)
    }

    func terminate(pid: Int32) {
        server.terminate(pid: pid, owner: owner)
    }
}
