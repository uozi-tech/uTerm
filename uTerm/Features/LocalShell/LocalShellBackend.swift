import Foundation

/// 本机 shell 的终端后端。shell 和伪终端都在 `uterm-holder` 里，App 退出、崩溃都不影响；这里只是连上去收发帧。
/// 连接由 XPC 服务建好交过来（见 `LocalShellAgentClient`）。
actor LocalShellBackend: HeldTerminalBackend, TerminalImageReceiving {
    private let core = HeldSessionCore()
    nonisolated var outputStream: AsyncStream<Data> { core.outputStream }
    nonisolated var exitStream: AsyncStream<Void> { core.exitStream }
    nonisolated var holderLink: HolderLink { core.holderLink }

    private let client: LocalShellAgentClient
    private let namespace: String
    private let sessionID: UUID
    private let directory: String?
    private let initialColumns: Int
    private let initialRows: Int
    private let ownsResponsibility: Bool
    private let writeImageToPasteboard: @Sendable (TerminalImage) -> Void

    init(client: LocalShellAgentClient, namespace: String = LocalShellNamespace.current, sessionID: UUID = UUID(),
         directory: String? = nil, columns: Int, rows: Int, ownsResponsibility: Bool = false,
         writeImageToPasteboard: @escaping @Sendable (TerminalImage) -> Void = { RemotePasteboard.write($0) }) {
        self.ownsResponsibility = ownsResponsibility
        self.client = client
        self.namespace = namespace
        self.sessionID = sessionID
        self.directory = directory
        self.writeImageToPasteboard = writeImageToPasteboard
        initialColumns = max(1, columns)
        initialRows = max(1, rows)
    }

    /// 本机 shell 的进程号（已结束 / 未启动时 nil）。
    var pid: Int32? {
        get async { await core.pid }
    }

    /// shell 现在的工作目录（已结束 / 未启动时 nil）。问内核，所以 shell 不用配合，程序在前台跑着也问得到。
    func workingDirectory() async -> String? {
        guard let shell = await core.pid else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(shell, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    func connect() async throws {
        do {
            try await core.attach(try await open())
        } catch let error as HolderSessionFailure {
            // 上一个 holder 正在退出时可能连上它又立刻断开（重新启动已退出的 shell）。socket 文件这时已经没了，再来一次就是新的。
            guard case .disconnected = error else { throw error }
            try await core.attach(try await open())
        }
    }

    private func open() async throws -> FileHandle {
        try await client.openSession(namespace: namespace, id: sessionID, directory: directory, columns: initialColumns, rows: initialRows,
                                     ownsResponsibility: ownsResponsibility)
    }

    func takeReplay() async -> HolderReplay? {
        await core.takeReplay()
    }

    func write(_ data: Data) async {
        await core.write(data)
    }

    /// 本机 shell 里的程序就在这台 Mac 上：图片放进系统剪贴板，再替用户按一下 Ctrl+V
    ///（Claude Code 等 CLI 在 Ctrl+V 时从剪贴板读图；不认得的程序最多收到一个 ^V）。
    nonisolated var programsCanReadMacClipboard: Bool { true }

    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        guard await core.isConnected else { throw TerminalImageError.notConnected }
        writeImageToPasteboard(image)
        await write(Data([0x16]))
        return .clipboard
    }

    func resize(cols: UInt16, rows: UInt16) async {
        await core.resize(cols: cols, rows: rows)
    }

    func setAttributes(_ attributes: Data) async {
        await core.setAttributes(attributes)
    }

    /// 主端在 holder 手里，但内核记着 shell 的控制终端上前台进程组是谁，按 shell 的 pid 就能问到。
    func foregroundActivity() async -> TerminalActivity {
        guard let shell = await core.pid else { return .unknown }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, shell]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return .unknown }
        let foreground = info.kp_eproc.e_tpgid
        guard foreground > 0 else { return .unknown }
        // shell 是会话首进程，进程组号 = pid。
        if foreground == shell { return .idle }
        var name = [CChar](repeating: 0, count: 256)
        let length = proc_name(foreground, &name, UInt32(name.count))
        guard length > 0 else { return .running(nil) }
        let bytes = name.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return .running(String(decoding: bytes, as: UTF8.self))
    }

    func close() async {
        await core.close()
    }

    func detach() async {
        await core.detach()
    }
}
