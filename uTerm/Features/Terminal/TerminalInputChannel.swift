import Foundation

/// 键盘 / 粘贴字节与尺寸变化发往后端的通道。mac `TerminalSession` 与 iOS `MobileTerminalController` 共用。
///
/// 输入和尺寸走同一条 FIFO（一个 `AsyncStream` + 一个消费任务）：每次各起一个 `Task` 时，两个 Task
/// 谁先进后端 actor 没有语言层面的保证，快速连打、或者「打字 + 改尺寸」可能乱序。
///
/// 尺寸：
/// - `reportSize` 记下终端当前行列数，只合并同一轮主线程里的连续变化（`pinRemoteGrid` 会连设几次）后发一次。
///   不按时间防抖：尺寸已由容器（`GhosttyContainerView` / `MTerminalContainerView`）等停稳才提交，
///   缓冲区已经重排，程序越早知道越好。和这条后端上次发出的相同就不发——终端视图布局时会重复报同一个值，
///   每发一次远端就收一个 SIGWINCH，全屏程序整屏重绘一遍。
/// - `sendLatestSizeNow` 立刻补发当前尺寸，不去重（建连成功后、窗格重新显示时）。
/// - `latestSize` 跨绑定保留：换了后端仍知道终端多大。
///
/// 建连也排进这条 FIFO（`connect(_:)`）：绑定时排进去的尺寸一定先到后端。远控主控端靠这个让接入请求就带上本地网格
///（对端钉好这个尺寸再拍第一张快照，不必先按默认的 80×24 接入、再改一次尺寸重发快照）。
@MainActor
final class TerminalInputChannel {
    typealias Size = (cols: UInt16, rows: UInt16)

    /// 终端最近一次报告的行列数；还没报告过为 nil。
    private(set) var latestSize: Size?
    /// 在当前绑定上最后发出（或排进队列）的尺寸。换绑定时清空。
    private var lastSentSize: Size?
    private var continuation: AsyncStream<Input>.Continuation?
    private weak var boundBackend: (any TerminalBackend)?
    private var pendingResize: Task<Void, Never>?

    private enum Input: Sendable {
        case data(Data)
        case resize(cols: UInt16, rows: UInt16)
        case connect(CheckedContinuation<Void, any Error>)
    }

    /// 之后的输入都发给 `backend`。先解除旧绑定。
    /// - Parameter sendingLatestSize: 立刻把 `latestSize` 排进队首（排在之后的 `connect(_:)` 前面）。尺寸可能早于后端就绪
    ///   （首次排布、重连），两端都在建连前绑定、靠它把尺寸带进建连（SSH 当 PTY 的初始尺寸，远控当接入请求的网格）。
    func bind(to backend: any TerminalBackend, sendingLatestSize: Bool) {
        unbind()
        let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
        self.continuation = continuation
        boundBackend = backend
        Task {
            for await input in inputs {
                switch input {
                case .data(let data): await backend.write(data)
                case .resize(let cols, let rows): await backend.resize(cols: cols, rows: rows)
                case .connect(let done):
                    do {
                        try await backend.connect()
                        done.resume()
                    } catch {
                        done.resume(throwing: error)
                    }
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
        boundBackend = nil
        continuation?.finish()
        continuation = nil
    }

    /// 让 `backend` 建连，排在这之前进队列的尺寸、输入之后；建连期间的键入排在它后面，连上再发。
    /// `backend` 已经不是绑着的那条（这期间换了绑定、解了绑）时直接建连，不经队列。
    func connect(_ backend: any TerminalBackend) async throws {
        guard let continuation, boundBackend === backend else {
            try await backend.connect()
            return
        }
        // 队列刚结束、`yield` 被拒时这一项不会有人取：放行，在这里自己建连。
        var enqueued = false
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            if case .enqueued = continuation.yield(.connect(done)) {
                enqueued = true
            } else {
                done.resume()
            }
        }
        if !enqueued { try await backend.connect() }
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
