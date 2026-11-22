import Foundation

/// 终端层（`TerminalSession`）所依赖的抽象后端。形态对齐 uService 的
/// `ProcessRunning`，去掉本地进程语义，改为连接语义。SSH 是 M1 唯一实现。
protocol TerminalBackend: Actor {
    /// 入站输出（远端 stdout/stderr 的字节，远控镜像还夹着整屏快照，见 `TerminalOutputItem`）。输出泵直接迭代它；
    /// 只出字节的后端用 `TerminalByteOutput` 造。
    nonisolated var outputItems: AsyncStream<TerminalOutputItem> { get }
    /// 画面的网格由对端定（远控镜像的主控端）：影子终端跟着对端发来的快照走、不跟本地 surface，网格对齐之前画面不跟
    /// （`TerminalOutputPump.followsSnapshotGrid`）。默认 false。
    nonisolated var mirrorsRemoteGrid: Bool { get }
    /// 远端会话结束时产出一个元素后结束。
    nonisolated var exitStream: AsyncStream<Void> { get }

    /// 建立连接并开启交互式 PTY shell。失败抛错。
    func connect() async throws
    /// 写入键盘字节。
    func write(_ data: Data) async
    /// 通知远端窗口尺寸变化（SIGWINCH）。
    func resize(cols: UInt16, rows: UInt16) async
    /// 关闭通道与连接。幂等。
    func close() async
    /// 主动探测连接是否仍然存活（系统唤醒 / 网络恢复后由看门狗调用）。
    /// 判死的实现应自行强制关闭底层通道，让 `exitStream` 走既有收尾级联；
    /// 调用方不需要根据返回值做状态翻转。
    func verifyConnectionAlive() async -> Bool
    /// 终端前台此刻有没有 shell 以外的程序在跑。关标签前问它，决定要不要二次确认。
    func foregroundActivity() async -> TerminalActivity
}

extension TerminalBackend {
    nonisolated var mirrorsRemoteGrid: Bool { false }

    /// 默认恒真 —— 非网络后端（测试 mock）没有「静默断死」的概念。
    func verifyConnectionAlive() async -> Bool { true }
    /// 默认判断不了：关闭前宁可多问一句。
    func foregroundActivity() async -> TerminalActivity { .unknown }
}

/// 只出字节的后端（SSH、本机 shell、holder，以及测试里的假后端）的输出流：收到的字节直接以 `.bytes` 进 `items`，
/// 会话那头直接迭代，不再经一层转发任务。
nonisolated struct TerminalByteOutput: Sendable {
    let items: AsyncStream<TerminalOutputItem>
    private let continuation: AsyncStream<TerminalOutputItem>.Continuation

    init() {
        (items, continuation) = AsyncStream.makeStream(of: TerminalOutputItem.self)
    }

    func send(_ data: Data) {
        continuation.yield(.bytes(data))
    }

    func finish() {
        continuation.finish()
    }
}

/// 能把图片交给终端里程序的后端。SSH 传成远端文件，Mac 本机 shell 走剪贴板，远控转交给 Mac。
protocol TerminalImageReceiving: TerminalBackend {
    /// 终端里的程序跑在这台 Mac 上，自己就能读剪贴板。
    nonisolated var programsCanReadMacClipboard: Bool { get }
    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery
}

nonisolated enum TerminalImageError: LocalizedError {
    case notConnected
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "终端尚未连接")
        case .unsupported(let message): return message
        }
    }
}

nonisolated extension TerminalImage {
    /// 远端临时文件名：`/tmp/uterm-image-20261103-153012-a1b2.png`。不带空格与引号，粘进 shell 不用转义。
    func temporaryRemotePath(now: Date = Date()) -> String {
        TerminalUploadPath.temporary(kind: "image", fileExtension: format.fileExtension, now: now)
    }
}
