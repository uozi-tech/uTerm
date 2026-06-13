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
}

extension TerminalBackend {
    /// 默认恒真 —— 非网络后端（测试 mock）没有「静默断死」的概念。
    func verifyConnectionAlive() async -> Bool { true }
}
