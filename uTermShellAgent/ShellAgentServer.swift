import Darwin
import Foundation
import os

/// 辅助程序本体：收连接（只认 uTerm 主程序）、拉起 holder、替主程序连 holder 的 socket。
///
/// 这里不留任何会话状态：会话归 holder，socket 目录就是真值。所以这个进程随 uTerm 退出也不影响任何 shell。
nonisolated final class ShellAgentServer: NSObject, NSXPCListenerDelegate, LocalShellAgentProtocol, @unchecked Sendable {
    static let version = "2"
    /// 等 holder 开始监听的上限。正常几毫秒。
    private static let spawnWaitSeconds = 5.0

    private let queue = DispatchQueue(label: "com.uozi.uTerm.ShellAgent")
    private let log = Logger(subsystem: "com.uozi.uTerm", category: "shell-agent")

    override init() {
        super.init()
        // holder 退出时不留僵尸（XPC 服务还活着的时候它是 holder 的父进程）。
        signal(SIGCHLD, SIG_IGN)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(LocalShellAgent.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: LocalShellAgentProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(reply: @escaping @Sendable (String) -> Void) {
        reply(Self.version)
    }

    func openSession(namespace: String, id: String, columns: Int, rows: Int,
                     reply: @escaping @Sendable (FileHandle?, String?) -> Void) {
        queue.async {
            do {
                let directory = try self.directory(namespace: namespace)
                let name = try Self.socketName(id: id)
                if let existing = self.connect(directory: directory, name: name) {
                    reply(existing, nil)
                    return
                }
                let pid = try self.spawnHolder(directory: directory, name: name, columns: columns, rows: rows)
                let deadline = Date().addingTimeInterval(Self.spawnWaitSeconds)
                while Date() < deadline {
                    if let connected = self.connect(directory: directory, name: name) {
                        reply(connected, nil)
                        return
                    }
                    guard kill(pid, 0) == 0 else { throw AgentError("holder 启动后立刻退出了，详情见 \(directory)/holder.log") }
                    usleep(5_000)
                }
                kill(pid, SIGKILL)
                throw AgentError("等 holder 就绪超时")
            } catch {
                self.log.error("起会话失败：\(error.localizedDescription, privacy: .public)")
                reply(nil, error.localizedDescription)
            }
        }
    }

    func connectSession(namespace: String, id: String, reply: @escaping @Sendable (FileHandle?, String?) -> Void) {
        queue.async {
            do {
                let directory = try self.directory(namespace: namespace)
                let name = try Self.socketName(id: id)
                guard let connected = self.connect(directory: directory, name: name) else {
                    throw AgentError("这个终端已经不在了")
                }
                reply(connected, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    func listSessions(namespace: String, reply: @escaping @Sendable ([String]) -> Void) {
        queue.async {
            guard let directory = try? self.directory(namespace: namespace),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                reply([])
                return
            }
            var live: [String] = []
            for name in names where name.hasSuffix(".sock") {
                if let connection = self.connect(directory: directory, name: name) {
                    try? connection.close()
                    live.append(String(name.dropLast(".sock".count)))
                } else {
                    unlink("\(directory)/\(name)")
                }
            }
            reply(live)
        }
    }

    // MARK: - 路径

    private static func socketName(id: String) throws -> String {
        // id 来自主程序，但要拼路径，只认 UUID。
        guard UUID(uuidString: id) != nil else { throw AgentError("会话 id 无效") }
        return id.lowercased() + ".sock"
    }

    private func directory(namespace: String) throws -> String {
        guard !namespace.isEmpty, namespace.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw AgentError("命名空间无效")
        }
        let path = NSHomeDirectory() + "/Library/Application Support/uTerm/sessions/" + namespace
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return path
    }

    // MARK: - 连接

    /// 切进目录用相对路径连：完整路径可能超过 `sun_path` 上限（用户名长的时候）。
    /// 工作目录是进程全局的，所以只在 `queue` 上调；别处都用绝对路径。
    private func connect(directory: String, name: String) -> FileHandle? {
        guard chdir(directory) == 0 else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(name.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        // XPC 编码回复时会 dup 一份，回复发出后这个 FileHandle 释放、关掉这边这份。
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - 拉起 holder

    private func spawnHolder(directory: String, name: String, columns: Int, rows: Int) throws -> pid_t {
        // .../uTerm.app/Contents/XPCServices/uTermShellAgent.xpc → .../uTerm.app/Contents/Helpers/uterm-holder
        let holder = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/uterm-holder").path
        guard FileManager.default.isExecutableFile(atPath: holder) else { throw AgentError("找不到 \(holder)") }
        let shell = Self.loginShell()
        let argv0 = "-" + (shell as NSString).lastPathComponent
        let arguments = [holder, directory, name, String(max(1, columns)), String(max(1, rows)), shell, argv0]
        let environment = Self.environment(shell: shell)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 新会话：脱离 XPC 服务的进程组，服务退出时 launchd 清进程组不会清到它。
        // 只把下面明确打开的 fd 带过去，别把 XPC 服务的东西漏给会活很久的进程。
        // 信号掩码和处置也要清：这个线程可能屏蔽着信号，带过去 holder 连 SIGTERM 都收不到。
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        let logPath = "\(directory)/holder.log"
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        let cArguments = arguments.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup($0) } + [nil]
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, holder, &actions, &attributes, cArguments, cEnvironment)
        guard result == 0 else { throw AgentError("起 holder 失败：\(String(cString: strerror(result)))") }
        log.info("起 holder \(name, privacy: .public) pid=\(pid) shell=\(shell, privacy: .public) \(columns)×\(rows)")
        return pid
    }

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
}

nonisolated private struct AgentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
