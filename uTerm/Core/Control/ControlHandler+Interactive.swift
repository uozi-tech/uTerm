import Darwin
import Foundation

/// `run -t`：人在自己的终端里跑 `utermctl run -t -H host -- cmd`，像 `ssh -t` 一样实时交互。
///
/// 客户端把终端切成 raw 模式，经 `SCM_RIGHTS` 交来三个 fd：stdin、stdout、一条窗口尺寸
/// 通知管道（读端）。uTerm 开一条 PTY，stdin 的字节原样写进去，PTY 的输出原样写回
/// stdout —— 终端字节不走 socket，socket 上照旧只有心跳和最后那一行结果（退出码）。
///
/// - Ctrl-C 等控制键在 raw 模式下是普通字节，送到远端 PTY 由那边的行规程处理。
/// - 管道读到 EOF = 客户端进程没了（终端窗口被关），立刻关通道；socket 写心跳撞 EPIPE 时
///   服务端取消 handler 任务，同样关通道。
/// - 不按静默超时（人可能盯着屏幕想半天），只有总时长上限 `--max-duration`。
extension ControlHandler {

    func interactiveRunResponse(
        _ request: ControlRequest,
        _ deps: Dependencies
    ) async throws -> ControlResponse {
        let profile = try resolveHost(request.host ?? "")
        try requireExecCapable(profile, action: .run)
        let command = try Self.optionalCommandText(request)

        guard let context = ControlRequestContext.current,
              let input = context.takeFileDescriptor(),
              let output = context.takeFileDescriptor()
        else {
            throw ControlFailure(
                code: .invalid_request,
                message: "run -t 需要客户端随请求交来 stdin / stdout（只能从真正的终端里用 utermctl 发起）"
            )
        }
        let bridge = TTYBridge(input: input, output: output, resize: context.takeFileDescriptor())
        let limits = Self.limits(request)

        let hostSpec: HostConnectionSpec
        do {
            hostSpec = try HostConnectionSpec.resolve(profile: profile, container: deps.modelContainer)
        } catch let error as ControlConnectError {
            bridge.closeDescriptors()
            return response(for: error, id: request.id, host: profile.name)
        }

        let spec = Self.ptySpec(request, defaultCols: 80, defaultRows: 24)
        let start = Date()
        let handle: any PTYHandle
        do {
            handle = try await deps.pool.openPTY(
                for: hostSpec,
                spec: spec,
                onOutput: { bridge.remoteOutput($0) },
                onEnd: { bridge.remoteEnded($0) }
            )
        } catch {
            bridge.closeDescriptors()
            if let connect = error as? ControlConnectError {
                return response(for: connect, id: request.id, host: profile.name)
            }
            if let failure = error as? ControlFailure { throw failure }
            throw ControlFailure(
                code: .operation_failed,
                message: "在「\(profile.name)」上开 PTY 失败：\(FriendlyError.describe(error))"
            )
        }
        bridge.attach(handle, command: command)

        // 等远端结束。期间不断报进展（不然服务端 120 秒静默闸会把人在思考的会话掐掉）。
        let clock = ContinuousClock()
        let started = clock.now
        let maxDuration = Duration.seconds(limits.maxDurationSeconds)
        var hitMaxDuration = false
        while bridge.ending == nil {
            IOActivity.touch()
            if Task.isCancelled || bridge.clientGone {
                handle.close()
            } else if clock.now - started >= maxDuration {
                hitMaxDuration = true
                handle.close()
            } else if bridge.isBootstrapping, clock.now - started >= Self.bootstrapTimeout {
                bridge.failBootstrap()
                handle.close()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await bridge.drainAndClose()

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        if let failure = bridge.bootstrapFailure {
            return .failure(id: request.id, code: .operation_failed, message: failure)
        }
        switch bridge.ending {
        case .exited(let code):
            return .success(
                id: request.id,
                message: "「\(profile.name)」上的交互命令已结束，退出码 \(code)",
                result: ControlRunResult(
                    host: profile.name, hostID: profile.id.uuidString, output: "",
                    exitCode: code, durationMs: durationMs)
            )
        case .failed(let message):
            return .failure(
                id: request.id,
                code: .connect_failed,
                message: "「\(profile.name)」的连接断了：\(message)"
            )
        case .closedLocally, .none:
            if hitMaxDuration {
                return .failure(
                    id: request.id,
                    code: .command_timeout,
                    message: "运行满 \(limits.maxDurationSeconds) 秒总时长上限，已关闭 PTY（远端进程随之收到 SIGHUP）",
                    results: [ControlRunResult(
                        host: profile.name, hostID: profile.id.uuidString, output: "",
                        durationMs: durationMs, timedOut: true, timeoutReason: "max_duration", killed: true)]
                )
            }
            return .failure(
                id: request.id,
                code: .operation_failed,
                message: "客户端已断开，已关闭「\(profile.name)」上的 PTY"
            )
        }
    }
}

/// 客户端终端 ↔ 远端 PTY 的字节泵。fd 的所有权在这里：`drainAndClose` / `closeDescriptors` 关。
nonisolated final class TTYBridge: @unchecked Sendable {
    private let input: Int32
    private let output: Int32
    private let resizeFD: Int32?

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.uozi.uTerm.control.tty-out")
    private let readQueue = DispatchQueue(label: "com.uozi.uTerm.control.tty-in")
    private var handle: (any PTYHandle)?
    private var bootstrap: PTYBootstrapFilter?
    private var command: String?
    private var inputSource: DispatchSourceRead?
    private var resizeSource: DispatchSourceRead?
    private var resizeBuffer = Data()
    private var endingValue: PTYEnding?
    private var gone = false
    private var bootstrapFailureText: String?
    private var closed = false

    init(input: Int32, output: Int32, resize: Int32?) {
        self.input = input
        self.output = output
        self.resizeFD = resize
    }

    var ending: PTYEnding? { lock.withLock { endingValue } }
    var clientGone: Bool { lock.withLock { gone } }
    var isBootstrapping: Bool { lock.withLock { bootstrap != nil } }
    var bootstrapFailure: String? { lock.withLock { bootstrapFailureText } }

    /// 通道开起来了。跑指定命令时先写引导行，就绪后才开始转发键盘 —— 不然用户先敲的
    /// 键会插进 base64 的命令行里。
    func attach(_ handle: any PTYHandle, command: String?) {
        lock.withLock {
            self.handle = handle
            self.command = command
            if command != nil { bootstrap = PTYBootstrapFilter() }
        }
        startResizeWatch()
        if command != nil {
            handle.write(ControlPTYCommand.bootstrapLine)
        } else {
            startInputPump()
        }
    }

    func remoteOutput(_ data: Data) {
        var deliver = data
        var payload: Data?
        var target: (any PTYHandle)?
        var overflowed = false
        lock.withLock {
            guard var filter = bootstrap else { return }
            let step = filter.feed(data)
            deliver = step.deliver
            if step.becameReady, let command {
                payload = ControlPTYCommand.payload(command)
                target = handle
            }
            if filter.overflowed {
                overflowed = true
                bootstrapFailureText = "登录 shell 输出了 \(PTYBootstrapFilter.limit / 1024) KiB 仍没有执行命令"
                target = handle
            }
            bootstrap = filter.isReady || filter.overflowed ? nil : filter
        }
        if overflowed {
            target?.close()
            return
        }
        if let payload {
            target?.write(payload)
            startInputPump()
        }
        guard !deliver.isEmpty else { return }
        let bytes = deliver
        writeQueue.async { [self] in
            guard !writeAll(bytes) else { return }
            markGone()
        }
    }

    func remoteEnded(_ ending: PTYEnding) {
        lock.withLock {
            if endingValue == nil { endingValue = ending }
            handle = nil
        }
    }

    func failBootstrap() {
        lock.withLock {
            if bootstrapFailureText == nil {
                bootstrapFailureText = "登录 shell \(Int(ControlHandler.bootstrapTimeout.components.seconds)) 秒内没有执行命令"
                    + "（.bashrc / .zshrc 里自动起 tmux、或者在等输入？）"
            }
            bootstrap = nil
        }
    }

    /// 等还没写完的输出写完，停掉读源，关 fd。
    func drainAndClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { continuation.resume() }
        }
        closeDescriptors()
    }

    /// 关掉全部 fd（幂等）。挂着读源的 fd 由读源的取消回调关，免得撞上还在跑的事件处理；
    /// 没挂读源的直接关。
    func closeDescriptors() {
        let state = lock.withLock { () -> (input: DispatchSourceRead?, resize: DispatchSourceRead?, done: Bool) in
            defer { closed = true }
            return (inputSource, resizeSource, closed)
        }
        guard !state.done else { return }
        if let source = state.input { source.cancel() } else { Darwin.close(input) }
        if let resizeFD {
            if let source = state.resize { source.cancel() } else { Darwin.close(resizeFD) }
        }
        Darwin.close(output)
    }

    // MARK: - 泵

    private func startInputPump() {
        let fd = input
        // 建源、登记、resume 一气呵成地在锁里做：已经 `closeDescriptors` 过就不建（fd 已关）；
        // 建了不 resume 的源被释放会直接崩。
        lock.lock()
        defer { lock.unlock() }
        guard !closed, inputSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let target = self.lock.withLock { self.handle }
                target?.write(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // stdin 读到头（不是终端时的 EOF）或坏了：不再读，会话照常跑到远端结束。
                self.lock.withLock { self.inputSource }?.cancel()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        inputSource = source
        source.resume()
    }

    private func startResizeWatch() {
        guard let fd = resizeFD else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !closed, resizeSource == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 512)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                self.consumeResize(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // 写端只有客户端进程拿着：EOF = 客户端没了（终端窗口被关、进程被杀）。
                self.markGone()
                self.lock.withLock { self.resizeSource }?.cancel()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        resizeSource = source
        source.resume()
    }

    /// 通知管道里一行一条：`resize <cols> <rows>`。
    private func consumeResize(_ data: Data) {
        var sizes: [(Int, Int)] = []
        let target: (any PTYHandle)? = lock.withLock {
            resizeBuffer.append(data)
            while let newline = resizeBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: resizeBuffer[resizeBuffer.startIndex..<newline], as: UTF8.self)
                resizeBuffer.removeSubrange(resizeBuffer.startIndex...newline)
                let parts = line.split(separator: " ")
                if parts.count == 3, parts[0] == "resize",
                   let cols = Int(parts[1]), let rows = Int(parts[2]), cols > 0, rows > 0 {
                    sizes.append((min(cols, 1000), min(rows, 1000)))
                }
            }
            if resizeBuffer.count > 4096 { resizeBuffer.removeAll() }
            return handle
        }
        if let last = sizes.last { target?.resize(cols: last.0, rows: last.1) }
    }

    private func markGone() {
        lock.withLock { gone = true }
    }

    /// 阻塞写满（客户端的终端；`writeQueue` 上调用）。失败返回 false。
    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(output, pointer, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return false
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }
}
