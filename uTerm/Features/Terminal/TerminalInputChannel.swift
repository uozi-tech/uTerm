import Foundation

/// 键盘 / 粘贴字节与尺寸变化发往后端的通道。mac `TerminalSession` 与 iOS `MobileTerminalController` 共用。
///
/// 输入和尺寸走同一条 FIFO（一个 `AsyncStream` + 一个消费任务）：每次各起一个 `Task` 时，两个 Task
/// 谁先进后端 actor 没有语言层面的保证，快速连打、或者「打字 + 改尺寸」可能乱序。
///
/// 尺寸：
/// - `reportSize` 记下终端当前行列数，只合并同一轮主线程里的连续变化（`pinRemoteGrid` 会连设几次）后发一次。
///   不按时间防抖：尺寸已由容器（`TerminalContainerView` / `MTerminalContainerView`）等停稳才提交，
///   缓冲区已经重排，程序越早知道越好。和这条后端上次发出的相同就不发——SwiftTerm 布局时会重复报同一个值，
///   每发一次远端就收一个 SIGWINCH，全屏程序整屏重绘一遍。
/// - `sendLatestSizeNow` 立刻补发当前尺寸，不去重（建连成功后、窗格重新显示时）。
/// - `latestSize` 跨绑定保留：换了后端仍知道终端多大。
@MainActor
final class TerminalInputChannel {
    typealias Size = (cols: UInt16, rows: UInt16)

    /// 终端最近一次报告的行列数；还没报告过为 nil。
    private(set) var latestSize: Size?
    /// 在当前绑定上最后发出（或排进队列）的尺寸。换绑定时清空。
    private var lastSentSize: Size?
    private var continuation: AsyncStream<Input>.Continuation?
    private var pendingResize: Task<Void, Never>?

    private enum Input: Sendable {
        case data(Data)
        case resize(cols: UInt16, rows: UInt16)
    }

    /// 之后的输入都发给 `backend`。先解除旧绑定。
    /// - Parameter sendingLatestSize: 立刻把 `latestSize` 排进队首。尺寸可能早于后端就绪（首次排布、重连），
    ///   iOS 在建连前就绑定、靠它补发；mac 等连上之后自己调 `sendLatestSizeNow()`。
    func bind(to backend: any TerminalBackend, sendingLatestSize: Bool) {
        unbind()
        let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
        self.continuation = continuation
        Task {
            for await input in inputs {
                switch input {
                case .data(let data): await backend.write(data)
                case .resize(let cols, let rows): await backend.resize(cols: cols, rows: rows)
                }
            }
        }
        if sendingLatestSize, let latestSize { send(latestSize) }
    }

    /// 之后的输入一律丢弃。已经排进队列的照常发完（消费任务随队列结束）。
    func unbind() {
        pendingResize?.cancel()
        pendingResize = nil
        lastSentSize = nil
        continuation?.finish()
        continuation = nil
    }

    func write(_ data: Data) {
        continuation?.yield(.data(data))
    }

    func reportSize(cols: UInt16, rows: UInt16) {
        let size = (cols: cols, rows: rows)
        latestSize = size
        if let lastSentSize, lastSentSize == size {
            pendingResize?.cancel()
            pendingResize = nil
            return
        }
        pendingResize?.cancel()
        pendingResize = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.send(size)
        }
    }

    func sendLatestSizeNow() {
        guard let latestSize else { return }
        send(latestSize)
    }

    private func send(_ size: Size) {
        pendingResize?.cancel()
        pendingResize = nil
        lastSentSize = size
        continuation?.yield(.resize(cols: size.cols, rows: size.rows))
    }

    deinit {
        pendingResize?.cancel()
        continuation?.finish()
    }
}
