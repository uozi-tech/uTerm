import CoreServices
import CryptoKit
import Darwin
import Foundation

/// 跑命令、改文件、等变化。
nonisolated extension RemoteFileService {
    // MARK: - 起子进程

    nonisolated struct SpawnResult {
        var result: RemoteFileExecResult
        var output: Data
    }

    /// 起一个子进程，把标准输出和标准错误合在一起收回来。没有标准输入。
    ///
    /// - `idleSeconds`：连续这么久没有输出就判定卡住；`maxDuration`：总时长上限。到点终止整个进程组
    ///   （先 TERM，3 秒后 KILL）。
    /// - 输出超过 `maxBytes` 时只留最后一段：命令卡在哪、错在哪通常写在最后几行。
    static func spawn(executable: String, arguments: [String], directory: String?, environment: [String]? = nil,
                      idleSeconds: TimeInterval, maxDuration: TimeInterval, maxBytes: Int) throws -> SpawnResult {
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { throw RemoteFileError(.failed, String(localized: "建管道失败：\(String(cString: strerror(errno)))")) }
        let readEnd = pipeEnds[0]
        let writeEnd = pipeEnds[1]
        defer { close(readEnd) }
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFL, O_NONBLOCK)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        // 新会话：子进程自成一个进程组，超时时连它起的后台进程一起终止。
        // 先挂起：等退出监视装好再放行（见 `ExitWatch`），退出得再快也不会漏。
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_START_SUSPENDED))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory) }

        let cArguments = arguments.map { strdup($0) } + [nil]
        let cEnvironment = (environment ?? defaultEnvironment()).map { strdup($0) } + [nil]
        defer {
            cArguments.forEach { free($0) }
            cEnvironment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let started = Date()
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, cArguments, cEnvironment)
        close(writeEnd)
        guard spawned == 0 else {
            throw RemoteFileError(spawned == ENOENT ? .notFound : .failed,
                                  String(localized: "\(executable) 起不来：\(String(cString: strerror(spawned)))"))
        }
        let watch = ExitWatch(pid)
        defer { watch.close() }
        kill(pid, SIGCONT)

        var output = Data()
        var truncated = false
        var lastOutput = Date()
        var timeoutReason: String?
        var status: Int32 = 0
        var exited = false
        var exitedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func keep(_ count: Int) {
            output.append(contentsOf: buffer[0..<count])
            if output.count > maxBytes * 2 {
                output = Data(output.suffix(maxBytes))
                truncated = true
            }
        }

        loop: while true {
            // 一直在刷输出的命令（`tail -f`、`yes`）走不到下面的检查，总时长在这里先看。
            if !exited, Date().timeIntervalSince(started) > maxDuration {
                timeoutReason = "max_duration"
                break loop
            }
            var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0 {
                let got = Darwin.read(readEnd, &buffer, buffer.count)
                if got > 0 {
                    keep(got)
                    lastOutput = Date()
                    continue
                }
                // 写端全关了：子进程和它留下的后台进程都不会再有输出。
                if got == 0 { break loop }
                if errno != EAGAIN, errno != EINTR { break loop }
            }
            if !exited, watch.exited(status: &status) {
                exited = true
                exitedAt = Date()
            }
            // 命令自己退出了、但它放到后台的进程还占着管道：再等一小会儿把已有的输出收完就走。
            if let exitedAt, Date().timeIntervalSince(exitedAt) > 0.3 { break loop }
            guard !exited else { continue }
            if Date().timeIntervalSince(lastOutput) > idleSeconds {
                timeoutReason = "idle"
                break loop
            }
        }

        var killed = false
        if timeoutReason != nil, !exited {
            killed = terminateGroup(pid, watch: watch, status: &status)
            exited = killed
        }
        if !exited {
            // 正常结束：管道已经关了，等它退出拿状态。
            exited = watch.exited(status: &status, wait: 10)
        }
        if output.count > maxBytes {
            output = Data(output.suffix(maxBytes))
            truncated = true
        }
        // 没等到退出状态（极少见）就不报退出码，不拿 0 充数。
        let exitCode: Int32? = exited && (status & 0x7F) == 0 ? (status >> 8) & 0xFF : nil
        return SpawnResult(result: RemoteFileExecResult(exitCode: timeoutReason == nil ? exitCode : nil,
                                                        timedOut: timeoutReason != nil, timeoutReason: timeoutReason,
                                                        killed: killed, truncated: truncated,
                                                        durationMs: Int(Date().timeIntervalSince(started) * 1000)),
                           output: output)
    }

    /// 终止整个进程组：TERM，等 3 秒，还在就 KILL。回是否确实结束了。
    private static func terminateGroup(_ pid: pid_t, watch: ExitWatch, status: inout Int32) -> Bool {
        kill(-pid, SIGTERM)
        if watch.exited(status: &status, wait: 3) { return true }
        kill(-pid, SIGKILL)
        return watch.exited(status: &status, wait: 2)
    }

    /// 等一个子进程退出并拿到它的退出状态，不依赖 `waitpid`。
    ///
    /// 辅助程序把 `SIGCHLD` 设成了忽略（它起的 holder 退出时不留僵尸），那种进程里子进程一退出就被内核
    /// 收掉，`waitpid` 只会回 `ECHILD`、状态永远是 0：`exit 7` 会被报成成功，`git` 失败会被当成「一个文件
    /// 都没有」。kqueue 的 `NOTE_EXITSTATUS` 在退出那一刻就把状态带出来，和 `SIGCHLD` 怎么设无关。
    nonisolated final class ExitWatch {
        private let pid: pid_t
        private let queue: Int32
        private var registered = false
        private var result: Int32?

        init(_ pid: pid_t) {
            self.pid = pid
            queue = kqueue()
            guard queue >= 0 else { return }
            var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                                fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            registered = kevent(queue, &change, 1, nil, 0, nil) == 0
        }

        /// 进程退出了没有；`wait` 是最多等几秒。退出了就把 `wait(2)` 形状的状态写进 `status`。
        func exited(status: inout Int32, wait: TimeInterval = 0) -> Bool {
            if let result {
                status = result
                return true
            }
            let deadline = Date().addingTimeInterval(wait)
            repeat {
                if poll(&status) { return true }
                if wait > 0 { usleep(20_000) }
            } while Date() < deadline
            return false
        }

        private func poll(_ status: inout Int32) -> Bool {
            if registered {
                var event = kevent()
                var none = timespec(tv_sec: 0, tv_nsec: 0)
                if kevent(queue, nil, 0, &event, 1, &none) == 1 {
                    result = Int32(truncatingIfNeeded: event.data)
                    // `SIGCHLD` 没被忽略的进程里它还是个僵尸：收掉。已经被内核收掉了就是 ECHILD，无妨。
                    var ignored: Int32 = 0
                    _ = waitpid(pid, &ignored, WNOHANG)
                }
            } else {
                // 监视没装上（kqueue 开不出来）：退回 waitpid，至少在没忽略 `SIGCHLD` 的进程里是对的。
                var raw: Int32 = 0
                let waited = waitpid(pid, &raw, WNOHANG)
                if waited == pid { result = raw } else if waited < 0, errno == ECHILD { result = 0 }
            }
            guard let result else { return false }
            status = result
            return true
        }

        func close() {
            if queue >= 0 { Darwin.close(queue) }
        }
    }

    static func defaultEnvironment() -> [String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("XPC_") && !key.hasPrefix("__CF")
        }
        environment["TERM"] = environment["TERM"] ?? "dumb"
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, access(path, X_OK) == 0 { return path }
        }
        return "/bin/zsh"
    }

    // MARK: - 跑命令

    /// 在用户的登录 shell 里跑一整串命令（管道、重定向、`;` 都行），目录缺省是主目录。
    static func exec(_ request: RemoteFileRequest, reply: inout RemoteFileReply, output: inout Data) throws {
        guard let command = request.command, !command.isEmpty else { throw RemoteFileError(.invalid, String(localized: "缺少要跑的命令")) }
        let directory = try resolve(request.path ?? "~")
        var info = Darwin.stat()
        guard stat(directory, &info) == 0 else { throw posixError(directory) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw posixError(directory, ENOTDIR) }
        let shell = loginShell()
        let spawned = try spawn(executable: shell, arguments: [shell, "-l", "-c", command], directory: directory,
                                idleSeconds: min(max(1, request.seconds ?? 60), 1800),
                                maxDuration: min(max(1, request.maxDuration ?? 3600), 21600),
                                maxBytes: min(max(1, request.maxBytes ?? 16000), RemoteFileLimits.maxChunkBytes))
        reply.exec = spawned.result
        reply.path = directory
        output = spawned.output
    }

    // MARK: - 改文件

    /// 把文件里的一段文字换成另一段。要换的文字必须正好出现一次，除非说了全部替换。
    static func edit(_ request: RemoteFileRequest, reply: inout RemoteFileReply) throws {
        let path = try resolve(request.path)
        guard let oldText = request.oldText, !oldText.isEmpty else { throw RemoteFileError(.invalid, String(localized: "缺少要换掉的文字")) }
        guard let newText = request.newText else { throw RemoteFileError(.invalid, String(localized: "缺少换成什么")) }
        let data = try loadText(path)
        if let expected = request.ifMatch {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw RemoteFileError(.conflict, String(localized: "\(path)：文件已经变了（现在的 sha256 是 \(actual)），重新读一遍再改"))
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteFileError(.invalid, String(localized: "\(path) 不是 UTF-8 文本，不能这样改"))
        }
        let count = text.components(separatedBy: oldText).count - 1
        guard count > 0 else { throw RemoteFileError(.noMatch, String(localized: "\(path) 里没有找到要换掉的文字")) }
        guard count == 1 || request.has(RemoteFileOption.all) else {
            throw RemoteFileError(.ambiguous, String(localized: "\(path) 里要换掉的文字出现了 \(count) 次：多带几行上下文让它唯一，或者说明全部替换"))
        }
        let updated = Data(text.replacingOccurrences(of: oldText, with: newText).utf8)
        try writeAtomically(updated, to: path, mode: nil)
        reply.count = count
        reply.sha256 = SHA256.hash(data: updated).map { String(format: "%02x", $0) }.joined()
        reply.size = Int64(updated.count)
        reply.path = path
    }

    /// 打一份 unified diff。交给系统自带的 `/usr/bin/patch`，输出原样回去。
    static func patch(_ request: RemoteFileRequest, body: Data, reply: inout RemoteFileReply, output: inout Data) throws {
        let directory = try resolve(request.path ?? "~")
        guard !body.isEmpty else { throw RemoteFileError(.invalid, String(localized: "补丁是空的")) }
        let diff = NSTemporaryDirectory() + "uterm-patch-\(UUID().uuidString).diff"
        guard FileManager.default.createFile(atPath: diff, contents: body, attributes: [.posixPermissions: 0o600]) else {
            throw RemoteFileError(.failed, String(localized: "写不了临时补丁文件"))
        }
        defer { unlink(diff) }
        var arguments = ["patch", "-p\(max(0, request.strip ?? 1))", "--batch", "--forward", "--no-backup-if-mismatch",
                         "-r", "-", "-i", diff]
        if request.has(RemoteFileOption.dryRun) { arguments.append("--dry-run") }
        let spawned = try spawn(executable: "/usr/bin/patch", arguments: arguments, directory: directory,
                                idleSeconds: 30, maxDuration: 120, maxBytes: 64 * 1024)
        reply.exec = spawned.result
        reply.path = directory
        output = spawned.output
        if spawned.result.exitCode != 0 {
            let detail = String(decoding: spawned.output.suffix(2000), as: UTF8.self)
            throw RemoteFileError(.conflict, String(localized: "补丁没打上：\(detail)"))
        }
    }

    // MARK: - 等变化

    /// 等到 `path`（文件，或目录连同它下面的一切）有变化，或者到时限。
    static func waitChange(_ request: RemoteFileRequest, reply: inout RemoteFileReply) throws {
        let path = try realPath(resolve(request.path))
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { throw posixError(path) }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let watched = isDirectory ? path : (path as NSString).deletingLastPathComponent
        let seconds = min(max(0.1, request.seconds ?? 30), 600)

        // 调用之前刚发生的写入，事件可能这时候才送到（「写完文件马上等变化」是最常见的用法）：
        // 启动后先把在途的事件排空丢掉，之后到的再按文件的变更时间核一遍，早于这一刻的不算。
        var now = timeval()
        gettimeofday(&now, nil)
        let box = ChangeBox(only: isDirectory ? nil : path, since: Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, changeCallback, &context, [watched] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            throw RemoteFileError(.failed, String(localized: "没法监视 \(path)"))
        }
        let queue = DispatchQueue(label: "com.uozi.uTerm.files.watch")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw RemoteFileError(.failed, String(localized: "没法监视 \(path)"))
        }
        FSEventStreamFlushSync(stream)
        box.arm()
        let changed = box.signal.wait(timeout: .now() + seconds) == .success
        // 一次保存往往是连着的好几个事件：再等一小会儿把它们收齐。
        if changed { usleep(150_000) }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // 回调都在这个队列上：排空之后 box 不会再被碰。
        queue.sync {}
        reply.path = path
        reply.timedOut = !changed
        reply.names = box.paths()
    }

    nonisolated final class ChangeBox: @unchecked Sendable {
        let signal = DispatchSemaphore(value: 0)
        private let only: String?
        private let since: Double
        private let lock = NSLock()
        private var seen: [String] = []
        private var signalled = false
        private var armed = false

        init(only: String?, since: Double) {
            self.only = only
            self.since = since
        }

        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        /// 这个路径是不是在开始等之后才变的。已经不在了的算（删除、改名走了）。
        private func isFresh(_ path: String) -> Bool {
            var info = Darwin.stat()
            guard lstat(path, &info) == 0 else { return true }
            let changed = Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000
            return changed >= since
        }

        func add(_ incoming: [String]) {
            lock.lock()
            defer { lock.unlock() }
            guard armed else { return }
            for path in incoming {
                if let only, path != only { continue }
                guard isFresh(path) else { continue }
                if !seen.contains(path), seen.count < 100 { seen.append(path) }
                if !signalled {
                    signalled = true
                    signal.signal()
                }
            }
        }

        func paths() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }
}

nonisolated private func changeCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
                            _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
                            _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    Unmanaged<RemoteFileService.ChangeBox>.fromOpaque(info).takeUnretainedValue().add(list)
}
