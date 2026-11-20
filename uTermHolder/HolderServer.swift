import Darwin
import Dispatch
import Foundation
import Security

/// 一个会话的全部状态。只在主队列上读写（进程里只跑 `dispatchMain`）。
///
/// 这里故意不懂终端：不解析字节，检查点对它也只是一块不透明的数据。终端解析器和 SSH 栈都在频繁变，
/// holder 不跟它们绑在一起，才能做到升级 uTerm 不碰 PTY。
final class HolderServer: @unchecked Sendable {
    /// 能连 holder 的只有同团队签名的 uTerm。目录权限 0700 已经挡住别的用户，这里再挡同用户的其它程序。
    ///
    /// 两个身份都要放行：连接是 XPC 服务建的，但 `LOCAL_PEERTOKEN` 查到的是**最后动过对端 socket 的进程**。
    /// fd 交给主程序后，主程序抢在这边 `accept` 之前发了数据，查到的就是主程序。
    private static let peerRequirement =
        CodeSigningTeam.requirement(identifiers: [AppIdentity.shellAgent, AppIdentity.app])
    private static let killGraceSeconds = 3
    /// shell 在 App 不在时退出：留着最后一屏等 App 回来，但不能永远等。
    private static let exitedLingerSeconds = 24 * 60 * 60
    private static let pauseAboveBytes = 1024 * 1024
    private static let resumeBelowBytes = 256 * 1024
    /// 输入积压暂停读 App 之后，这么久一个字节都没写进 PTY：前台程序不读 stdin，积压的再等也送不进去。
    private static let inputStallSeconds = 10

    private let directory: String
    private let socketName: String
    private let workingDirectory: String
    private let executable: String
    private let argv: [String]
    /// `uterm-ssh` 会话：XPC 服务放在这个 fd 上的控制通道要留给子进程。本机 shell 没有。
    private let childControlFD: Int32?
    private var cols: UInt16
    private var rows: UInt16
    private let createdAt = UInt64(Date().timeIntervalSince1970)

    private var master: Int32 = -1
    private var shellPID: pid_t = -1
    private var masterRead: DispatchSourceRead?
    private var masterWrite: DispatchSourceWrite?
    private var isMasterReadPaused = false
    private var isMasterWriteArmed = false
    private var isMasterClosed = false
    private var pendingInput = HolderByteQueue()
    /// 累计写进 PTY 的输入字节，判断积压有没有在动。
    private var inputWrittenTotal: UInt64 = 0
    private var isInputStallCheckScheduled = false
    private var log = HolderOutputLog()
    private var checkpoint: HolderCheckpoint?
    private var attributes: [UInt8] = []
    private var exitStatus: Int32?
    private var isTerminating = false
    private var listenSource: DispatchSourceRead?
    private var clients: [ObjectIdentifier: HolderClient] = [:]
    private var attached: HolderClient?
    private var processSource: DispatchSourceProcess?
    private var isSocketRemoved = false
    /// 到 `uterm-ssh` 的转发通道。持有连接的是它，App 要在这条连接上跑命令得经这里。
    private var childRelay: HolderClient?

    init(directory: String, socketName: String, cols: UInt16, rows: UInt16, workingDirectory: String,
         executable: String, argv: [String],
         childControlFD: Int32? = nil) {
        self.directory = directory
        self.socketName = socketName
        self.cols = cols
        self.rows = rows
        self.workingDirectory = workingDirectory
        self.executable = executable
        self.argv = argv
        self.childControlFD = childControlFD
    }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        // XPC 服务把 SIGCHLD 设成了忽略，会被继承：那样 waitpid 拿不到退出码，shell 也会带着这个设置起来。
        signal(SIGCHLD, SIG_DFL)
        // socket 路径可能超过 sun_path 上限（用户名长）。切进目录用相对路径绑定；shell 的工作目录在子进程里另外设。
        guard chdir(directory) == 0 else { fail("进不去 socket 目录") }
        let listener = listen()
        // 先开始监听再起 shell：XPC 服务连得上，就说明 shell 已经起来了。
        spawnShell()
        startMasterIO()
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptClient(listener) }
        source.resume()
        listenSource = source
    }

    private func fail(_ message: String) -> Never {
        fputs("uterm-holder: \(message): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    // MARK: - socket

    private func listen() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketName.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { fail("socket 文件名过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
        // 走到这里说明 XPC 服务连不上旧 socket，留下的文件是上一个 holder 的残骸。
        unlink(socketName)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { fail("bind") }
        guard Darwin.listen(fd, 8) == 0 else { fail("listen") }
        return fd
    }

    private func acceptClient(_ listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard peerIsAllowed(fd) else {
            close(fd)
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let client = HolderClient(fd: fd)
        client.onFrame = { [weak self, weak client] frame in
            guard let self, let client else { return }
            self.handle(frame, from: client)
        }
        client.onClosed = { [weak self, weak client] in
            guard let self, let client else { return }
            self.clientClosed(client)
        }
        client.onQueueDrained = { [weak self, weak client] in
            guard let self, client === self.attached else { return }
            self.resumeMasterReadIfDrained()
        }
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    private func peerIsAllowed(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let guest = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, guest, [], &code)
        guard status == errSecSuccess, let code else {
            fputs("uterm-holder: 取不到对端的代码身份：\(status)\n", stderr)
            return false
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(Self.peerRequirement as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            fputs("uterm-holder: 签名要求无效：\(status)\n", stderr)
            return false
        }
        status = SecCodeCheckValidity(code, [], requirement)
        if status != errSecSuccess { fputs("uterm-holder: 对端签名不符：\(status)\n", stderr) }
        return status == errSecSuccess
    }

    // MARK: - 帧

    private func handle(_ frame: HolderFrame, from client: HolderClient) {
        // 不认识的帧忽略：新版 App 可能连着旧 holder。
        guard let kind = frame.kind else { return }
        switch kind {
        case .hello:
            client.send(HolderFrame(.helloReply, payload: HolderHelloReply(
                version: HolderProtocol.version, shellPID: shellPID, createdAt: createdAt, cols: cols, rows: rows,
                exitStatus: exitStatus, attributes: attributes).encoded()))
        case .attach:
            attach(client)
        case .input:
            guard client === attached else { return }
            writeInput(frame.payload)
        case .resize:
            guard client === attached else { return }
            var reader = HolderByteReader(frame.payload)
            guard let newCols = reader.u16(), let newRows = reader.u16() else { return }
            resize(cols: newCols, rows: newRows)
        case .checkpoint:
            guard client === attached, var received = HolderCheckpoint(decoding: frame.payload) else { return }
            received.hasGap = false
            checkpoint = received
        case .setAttributes:
            attributes = frame.payload
        case .terminate:
            terminate()
        case .redraw:
            guard client === attached, !isMasterClosed else { return }
            let group = tcgetpgrp(master)
            if group > 0 { kill(-group, SIGWINCH) }
        case .probe:
            guard childControlFD != nil, exitStatus == nil else { return }
            kill(shellPID, SIGUSR1)
        case .childRequest:
            guard client === attached else { return }
            childRelay?.send(frame)
        case .helloReply, .replayCheckpoint, .output, .replayEnd, .exited, .replaced, .childReply:
            break
        }
    }

    /// 接入：把这个客户端不在期间的东西补给它，之后的输出接着流。同一时刻只有一个客户端。
    private func attach(_ client: HolderClient) {
        if let previous = attached, previous !== client {
            previous.send(HolderFrame(.replaced))
            previous.closeAfterFlush()
        }
        attached = client
        let start = checkpoint?.offset ?? 0
        let hasGap = start < log.startOffset
        client.send(HolderFrame(.replayCheckpoint, payload: HolderCheckpoint(
            offset: start, cols: checkpoint?.cols ?? cols, rows: checkpoint?.rows ?? rows, hasGap: hasGap,
            blob: checkpoint?.blob ?? []).encoded()))
        var position = max(start, log.startOffset)
        while position < log.endOffset, let chunk = log.read(from: position, maxBytes: HolderProtocol.outputChunkBytes) {
            client.send(HolderFrame(.output, payload: chunk))
            position += UInt64(chunk.count)
        }
        var end = HolderByteWriter()
        end.u64(log.endOffset)
        client.send(HolderFrame(.replayEnd, payload: end.bytes))
        if let exitStatus {
            sendExited(exitStatus, to: client)
        }
        resumeMasterReadIfDrained()
    }

    private func clientClosed(_ client: HolderClient) {
        clients[ObjectIdentifier(client)] = nil
        if attached === client {
            attached = nil
            // 没人看了也要继续读：不读 shell 就会卡在写输出上。
            resumeMasterRead()
        }
        // 最后一屏已经交出去了，这个 holder 没有别的用处了。
        if client.sawExit { quit() }
    }

    private func sendExited(_ status: Int32, to client: HolderClient) {
        var writer = HolderByteWriter()
        writer.i32(status)
        client.send(HolderFrame(.exited, payload: writer.bytes))
        client.sawExit = true
        client.closeAfterFlush()
    }

    // MARK: - PTY

    private func spawnShell() {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cExecutable = strdup(executable)
        let cWorkingDirectory = strdup(workingDirectory)
        let cHome = strdup(NSHomeDirectory())
        let maxDescriptor = min(getdtablesize(), 4096)
        let keptDescriptor = childControlFD ?? -1
        var relay: [Int32] = [-1, -1]
        if childControlFD != nil {
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &relay) == 0 else { fail("socketpair") }
            _ = fcntl(relay[0], F_SETFD, FD_CLOEXEC)
        }
        let relayChildEnd = relay[1]
        let relayFD = HolderProtocol.childRelayFD
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &size)
        guard pid >= 0 else { fail("forkpty") }
        if pid == 0 {
            // 子进程里只调 async-signal-safe 的函数。这个进程的信号掩码和 SIGPIPE 设置 exec 之后还在，
            // 带过去的话 shell 里 ^C 都可能不灵。
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            signal(SIGPIPE, SIG_DFL)
            signal(SIGHUP, SIG_DFL)
            if relayChildEnd >= 0 { dup2(relayChildEnd, relayFD) }
            var descriptor: Int32 = 3
            while descriptor < maxDescriptor {
                if descriptor != keptDescriptor, relayChildEnd < 0 || descriptor != relayFD { close(descriptor) }
                descriptor += 1
            }
            // 目录可能刚被删掉：shell 还是要起来，落在主目录。
            if chdir(cWorkingDirectory) != 0 { _ = chdir(cHome) }
            _ = execv(cExecutable, cArgs)
            _exit(127)
        }
        master = fd
        shellPID = pid
        // 这一头留给子进程。这边还开着的话，子进程退出后 App 等不到控制通道断开。
        if let childControlFD { close(childControlFD) }
        if relayChildEnd >= 0 {
            close(relayChildEnd)
            startChildRelay(relay[0])
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.pollForExit(remainingAttempts: 50) }
        source.resume()
        processSource = source
        // 进程源注册之前就退出了的话，它不会再报。
        pollForExit(remainingAttempts: 1)
    }

    private func startChildRelay(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let relay = HolderClient(fd: fd)
        relay.onFrame = { [weak self] frame in
            self?.attached?.send(HolderFrame(.childReply, payload: frame.payload))
        }
        relay.onClosed = { [weak self] in self?.childRelay = nil }
        childRelay = relay
        relay.start()
    }

    private func startMasterIO() {
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        read.setEventHandler { [weak self] in self?.readMaster() }
        let write = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
        write.setEventHandler { [weak self] in self?.drainInput() }
        // 两个源都取消完才能关 fd。关掉之后还攥着从端的后台进程才会收到 SIGHUP。
        var liveSources = 2
        let fd = master
        let sourceCancelled = {
            liveSources -= 1
            if liveSources == 0 { close(fd) }
        }
        read.setCancelHandler(handler: sourceCancelled)
        write.setCancelHandler(handler: sourceCancelled)
        read.resume()
        masterRead = read
        masterWrite = write
    }

    private func readMaster() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total = 0
        while total < 256 * 1024 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                total += count
                buffer.withUnsafeBytes { log.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
                attached?.send(HolderFrame(.output, payload: Array(buffer[0..<count])))
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { break }
            // 0 或 EIO：从端全关了。shell 退出后才会到这里（后台进程还攥着从端时则要等它们也退出）。
            stopReadingMaster()
            pollForExit(remainingAttempts: 50)
            return
        }
        if let attached, attached.queuedBytes > Self.pauseAboveBytes, !isMasterReadPaused {
            masterRead?.suspend()
            isMasterReadPaused = true
        }
    }

    private func stopReadingMaster() {
        guard !isMasterClosed else { return }
        isMasterClosed = true
        if isMasterReadPaused {
            masterRead?.resume()
            isMasterReadPaused = false
        }
        masterRead?.cancel()
        if !isMasterWriteArmed { masterWrite?.resume() }
        masterWrite?.cancel()
        isMasterWriteArmed = false
    }

    private func resumeMasterRead() {
        guard isMasterReadPaused else { return }
        isMasterReadPaused = false
        masterRead?.resume()
    }

    private func resumeMasterReadIfDrained() {
        if let attached, attached.queuedBytes >= Self.resumeBelowBytes { return }
        resumeMasterRead()
    }

    /// 非阻塞写：主端一次只收约 1 KB，其余排队等可写。大段粘贴不能丢尾巴，也不能卡住这个进程唯一的队列。
    private func writeInput(_ bytes: [UInt8]) {
        guard !isMasterClosed else { return }
        pendingInput.append(bytes)
        drainInput()
        let paused = pendingInput.count > Self.pauseAboveBytes
        attached?.setReadingPaused(paused)
        if paused { scheduleInputStallCheck() }
    }

    /// 暂停读 App 的期间，App 后面发来的帧（关标签时的 terminate、改尺寸）都堵在积压的输入后面。
    /// 前台程序一直不读 stdin 就永远轮不到它们：关掉的标签留下一个没人管的 shell。
    /// 积压一段时间纹丝不动时丢掉它、恢复读，后面的帧才能进来。
    private func scheduleInputStallCheck() {
        guard !isInputStallCheckScheduled else { return }
        isInputStallCheckScheduled = true
        let mark = inputWrittenTotal
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.inputStallSeconds)) { [weak self] in
            guard let self else { return }
            isInputStallCheckScheduled = false
            guard pendingInput.count >= Self.resumeBelowBytes else { return }
            if inputWrittenTotal == mark {
                pendingInput = HolderByteQueue()
                attached?.setReadingPaused(false)
            } else {
                scheduleInputStallCheck()
            }
        }
    }

    private func drainInput() {
        guard !isMasterClosed else { return }
        while !pendingInput.isEmpty {
            let written = pendingInput.withReadable { write(master, $0.baseAddress, $0.count) }
            if written > 0 {
                pendingInput.consume(written)
                inputWrittenTotal &+= UInt64(written)
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                if !isMasterWriteArmed {
                    masterWrite?.resume()
                    isMasterWriteArmed = true
                }
                return
            }
            // EIO 等：shell 已经没了，退出路径会处理。
            pendingInput = HolderByteQueue()
            break
        }
        if isMasterWriteArmed {
            masterWrite?.suspend()
            isMasterWriteArmed = false
        }
        if pendingInput.count < Self.resumeBelowBytes { attached?.setReadingPaused(false) }
    }

    private func resize(cols newCols: UInt16, rows newRows: UInt16) {
        guard newCols > 0, newRows > 0 else { return }
        cols = newCols
        rows = newRows
        guard !isMasterClosed else { return }
        var size = winsize(ws_row: newRows, ws_col: newCols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    private func terminate() {
        isTerminating = true
        guard exitStatus == nil else { quit() }
        // 正在退出的会话不再接客。同一个 id 马上再开（关窗口后立刻重新打开）要得到新的会话，而不是接上一个将死的。
        removeSocket()
        kill(-shellPID, SIGHUP)
        kill(shellPID, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.killGraceSeconds)) { [weak self] in
            guard let self, self.exitStatus == nil else { return }
            kill(-self.shellPID, SIGKILL)
            kill(self.shellPID, SIGKILL)
        }
    }

    /// `NOTE_EXIT` 可能早于进程可以被 wait，也可能 PTY 先关，所以几条路都走到这里，轮询几次。
    private func pollForExit(remainingAttempts: Int) {
        guard exitStatus == nil else { return }
        var status: Int32 = 0
        let result = waitpid(shellPID, &status, WNOHANG)
        if result == shellPID {
            shellExited(status: status)
        } else if result < 0, errno == ECHILD {
            shellExited(status: 0)
        } else if remainingAttempts > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
                self?.pollForExit(remainingAttempts: remainingAttempts - 1)
            }
        }
    }

    private func shellExited(status: Int32) {
        exitStatus = status
        processSource?.cancel()
        // shell 退出前写的字节还在内核里，读完才算最后一屏。
        if !isMasterClosed { readMaster() }
        stopReadingMaster()
        if let attached {
            sendExited(status, to: attached)
        } else if isTerminating {
            quit()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.exitedLingerSeconds)) { [weak self] in self?.quit() }
        }
        // 关窗口时客户端随后就断开了，别让它们停在这里。
        if isTerminating {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in self?.quit() }
        }
    }

    private func quit() -> Never {
        removeSocket()
        exit(0)
    }

    /// 工作目录一直是 socket 目录（`start()` 切进来的），相对路径就是自己的 socket。只删一次：
    /// 删掉之后这个名字可能已经属于新的 holder。
    private func removeSocket() {
        guard !isSocketRemoved else { return }
        isSocketRemoved = true
        unlink(socketName)
    }
}

/// 一条客户端连接：切帧、排队发送。只在主队列上用。
final class HolderClient: @unchecked Sendable {
    private let fd: Int32
    private var reader = HolderFrameReader()
    private var outgoing = HolderByteQueue()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var isWriteArmed = false
    private var isReadPaused = false
    private var isClosed = false
    private var closesWhenFlushed = false

    var onFrame: ((HolderFrame) -> Void)?
    var onClosed: (() -> Void)?
    var onQueueDrained: (() -> Void)?
    /// 已经告诉这个客户端 shell 退出了。
    var sawExit = false

    var queuedBytes: Int { outgoing.count }

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        // fd 要等两个 source 都取消完才能关：先关的话 accept 可能马上复用这个编号，
        // 还没撤掉的 source 就盯在了新客户端的 fd 上。
        let closer = HolderFDCloser(fd: fd, sources: 2)
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        read.setCancelHandler { closer.sourceCancelled() }
        read.resume()
        readSource = read
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        write.setEventHandler { [weak self] in self?.flush() }
        write.setCancelHandler { closer.sourceCancelled() }
        writeSource = write
    }

    func setReadingPaused(_ paused: Bool) {
        guard paused != isReadPaused, !isClosed else { return }
        isReadPaused = paused
        if paused { readSource?.suspend() } else { readSource?.resume() }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            buffer.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            do {
                while !isClosed, let frame = try reader.next() { onFrame?(frame) }
            } catch {
                closeNow()
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            closeNow()
        }
    }

    func send(_ frame: HolderFrame) {
        guard !isClosed else { return }
        outgoing.append(frame.encoded())
        flush()
    }

    private func flush() {
        guard !isClosed else { return }
        while !outgoing.isEmpty {
            let written = outgoing.withReadable { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                outgoing.consume(written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                if !isWriteArmed {
                    writeSource?.resume()
                    isWriteArmed = true
                }
                onQueueDrained?()
                return
            } else {
                closeNow()
                return
            }
        }
        if isWriteArmed {
            writeSource?.suspend()
            isWriteArmed = false
        }
        onQueueDrained?()
        if closesWhenFlushed { closeNow() }
    }

    func closeAfterFlush() {
        closesWhenFlushed = true
        if outgoing.isEmpty {
            closeNow()
        } else {
            // 对端不读也不能一直挂着。
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in self?.closeNow() }
        }
    }

    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        if isReadPaused { readSource?.resume() }
        readSource?.cancel()
        if !isWriteArmed { writeSource?.resume() }
        writeSource?.cancel()
        // 没 start 过就没有 source 替它关。
        if readSource == nil { close(fd) }
        onClosed?()
    }
}

/// 两个 source 的取消回调都在主队列上，计数不用加锁。
private final class HolderFDCloser: @unchecked Sendable {
    private let fd: Int32
    private var remaining: Int

    init(fd: Int32, sources: Int) {
        self.fd = fd
        remaining = sources
    }

    func sourceCancelled() {
        remaining -= 1
        if remaining == 0 { close(fd) }
    }
}
