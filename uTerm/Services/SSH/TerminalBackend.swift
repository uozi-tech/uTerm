import Foundation

/// 终端层（`TerminalSession`）所依赖的抽象后端。形态对齐 uService 的
/// `ProcessRunning`，去掉本地进程语义，改为连接语义。SSH 是 M1 唯一实现。
protocol TerminalBackend: Actor {
    /// 入站字节（远端 stdout/stderr）。
    nonisolated var outputStream: AsyncStream<Data> { get }
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
    /// 默认恒真 —— 非网络后端（测试 mock）没有「静默断死」的概念。
    func verifyConnectionAlive() async -> Bool { true }
    /// 默认判断不了：关闭前宁可多问一句。
    func foregroundActivity() async -> TerminalActivity { .unknown }
}

/// 要交给终端里正在跑的程序的一张图片（手机相册 / 剪贴板来的）。
nonisolated struct TerminalImage: Equatable, Sendable {
    enum Format: UInt8, Sendable {
        case png = 2, jpeg = 3

        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    var format: Format
    var data: Data
}

/// 图片交出去之后的样子：调用方据此决定还要不要往终端里打字。
nonisolated enum TerminalImageDelivery: Equatable, Sendable {
    /// 放进了 Mac 的剪贴板并替用户按了 Ctrl+V（Mac 本机 shell：Claude Code 等直接从剪贴板读图）。
    case clipboard
    /// 传成了终端那台机器上的一个文件；调用方把路径粘进终端。
    case file(path: String)
}

/// 能把图片交给终端里程序的后端。SSH 传成远端文件，Mac 本机 shell 走剪贴板，远控转交给 Mac。
protocol TerminalImageReceiving: TerminalBackend {
    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery
}

nonisolated enum TerminalImageError: LocalizedError {
    case notConnected
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "终端还没连上"
        case .unsupported(let message): return message
        }
    }
}

nonisolated extension TerminalImage {
    /// 远端临时文件名：`/tmp/uterm-image-20261103-153012-a1b2.png`。不带空格与引号，粘进 shell 不用转义。
    func temporaryRemotePath(now: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "/tmp/uterm-image-\(stamp)-\(suffix).\(format.fileExtension)"
    }
}
