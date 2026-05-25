import SwiftUI
import SwiftTerm
import AppKit

/// Owns one `SwiftTerm.TerminalView` for the lifetime of its enclosing
/// terminal pane. The view is *not* recreated when the SwiftUI pane is
/// rebuilt (e.g. on maximize / restore), so the scrollback buffer survives
/// those layout changes. Acts as the view's delegate so user input / resize
/// are forwarded to the bound backend without needing a separate coordinator.
@MainActor
@Observable
final class TerminalSession: NSObject, TerminalViewDelegate {
    let terminalView: SwiftTerm.TerminalView
    private(set) var backend: (any TerminalBackend)?
    private var feedTask: Task<Void, Never>?
    @ObservationIgnored private let outputBuffer = TerminalOutputBuffer(capacityBytes: 4 * 1024 * 1024)
    @ObservationIgnored private var outputFlushTask: Task<Void, Never>?
    private var feedGeneration: Int = 0
    /// 输出活跃时的批合并节流。flush 后睡眠这么久再回头检查 buffer，让
    /// SwiftTerm 一次处理一批字节而不是逐字节渲染。≈60fps 上限。
    private let outputFlushActiveMs: Int = 16
    private let maxBytesPerOutputFlush = 32 * 1024

    // Resize forwarding state. SplitterHandle now updates `fraction` live during
    // drag, which makes SwiftTerm fire `sizeChanged` every layout pass. Without
    // a time debounce we'd SIGWINCH the remote 60+ times per second of
    // drag → TUI children (vim/htop) full-repaint each tick and flood the main
    // thread with their output. Coalesce to a single resize ~80ms after the
    // last `sizeChanged`. `lastForwardedResize` is kept as the fast-path
    // dedupe for "same dimensions" reports (no debounce needed in that case).
    @ObservationIgnored var latestReportedResize: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored var lastForwardedResize: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored var pendingResize: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored var resizeFlushTask: Task<Void, Never>?
    let resizeDebounceMs: Int = 80

    /// 终端连接状态。`connect(using:)` 推进；远端结束置 `disconnected`。
    enum ConnectionState: Equatable {
        case idle, connecting, connected, disconnected
        case failed(String)
    }
    private(set) var connectionState: ConnectionState = .idle
    @ObservationIgnored private var exitObserverTask: Task<Void, Never>?

    override init() {
        // Give SwiftTerm a non-trivial initial frame so its first `setFrameSize`
        // pass computes a meaningful `cellDimension` + initial cols/rows. With
        // `frame: .zero`, the very first layout has cellDimension nil → cols
        // stays at the default 80, and any PTY output that arrives before the
        // real SwiftUI-driven layout pass gets wrapped + frozen in scrollback
        // at 80 columns. Result: visible "dead zone" on the right side of the
        // pane until users scroll to brand-new output. 1280×800 ≈ a typical
        // pane size; SwiftUI overrides this on mount anyway, we only need a
        // sane initial so cellDimension is valid when the first frame arrives.
        self.terminalView = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        super.init()
        TerminalTheme.apply(to: terminalView, settings: TerminalSettings.read())
        terminalView.terminalDelegate = self
        terminalView.menu = Self.makeContextMenu(for: terminalView)
    }

    /// Right-click context menu for the live terminal. SwiftTerm's
    /// `TerminalView` implements `copy:`, `paste:`, and `selectAll:` (plus
    /// `validateUserInterfaceItem` to enable/disable them) but ships no context
    /// menu — `Cmd+C` was the only copy affordance. Items target the terminal
    /// view directly so a right-click acts on this pane's selection regardless
    /// of which view currently holds first responder.
    private static func makeContextMenu(for terminalView: SwiftTerm.TerminalView) -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        for item in [copyItem, pasteItem, selectAllItem] {
            item.target = terminalView
        }
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(selectAllItem)
        return menu
    }

    /// Call before letting ARC release this session. Severs the SwiftTerm
    /// delegate link (which is unowned-unsafe), cancels in-flight tasks, and
    /// prevents post-dealloc callbacks → objc_release crashes. Must run on
    /// the MainActor (the type is @MainActor so this is enforced by Swift).
    func dispose() {
        resetFeedAndResizeState()
        terminalView.terminalDelegate = nil
        backend = nil
    }

    var currentProcessSize: (cols: UInt16, rows: UInt16) {
        latestReportedResize ?? (cols: 120, rows: 30)
    }

    /// 用给定后端建立连接：connect() 成功则绑定并开始泵送输出，
    /// 失败置 failed，远端结束置 disconnected。
    func connect(using backend: any TerminalBackend) async {
        resetFeedAndResizeState()
        // `resetFeedAndResizeState()` just bumped `feedGeneration`; snapshot it
        // as this call's identity token. `backend.connect()` below suspends and
        // frees the MainActor — a second `connect(using:)`, `dispose()`, or
        // `detach()` can run during that gap and bump `feedGeneration` again.
        // When this call resumes it must not clobber the newer binding's state.
        let myGen = feedGeneration
        self.backend = backend
        connectionState = .connecting
        do {
            try await backend.connect()
        } catch {
            // Superseded while suspended — a newer connect/dispose owns the
            // session now; don't overwrite its state or clear its backend.
            guard feedGeneration == myGen else { return }
            connectionState = .failed("\(error)")
            self.backend = nil
            return
        }
        // Superseded check: bail unless this is still the live binding. The
        // `===` identity guard rejects the case where a newer connect bound a
        // different backend at the same generation boundary.
        guard feedGeneration == myGen, self.backend === backend else { return }
        connectionState = .connected
        if let latestReportedResize {
            forwardResizeImmediately(latestReportedResize)
        }
        startFeedLoop()
        startOutputFlushLoop()
        observeExit(of: backend, generation: myGen)
    }

    private func observeExit(of backend: any TerminalBackend, generation: Int) {
        exitObserverTask?.cancel()
        exitObserverTask = Task { [weak self] in
            for await _ in backend.exitStream {
                await MainActor.run { [weak self] in
                    // Guard on the generation token, not just the enum value:
                    // an exit event from an old backend could otherwise flip a
                    // healthy newer session to `.disconnected`.
                    guard let self, self.feedGeneration == generation else { return }
                    if self.connectionState == .connected {
                        self.connectionState = .disconnected
                    }
                }
            }
        }
    }

    func refreshTerminalSizeSoon() {
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
        if let latestReportedResize {
            forwardResizeImmediately(latestReportedResize)
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.terminalView.needsLayout = true
            self.terminalView.layoutSubtreeIfNeeded()
            if let latestReportedResize = self.latestReportedResize {
                self.forwardResizeImmediately(latestReportedResize)
            }
        }
    }

    /// Clears the visible terminal and scrollback without detaching from the
    /// backend, so new output continues to stream into the same view.
    func clearOutput() {
        outputBuffer.clear()
        let bytes = Array("\u{1B}[3J\u{1B}[H\u{1B}[2J".utf8)
        terminalView.feed(byteArray: ArraySlice(bytes))
    }

    func detach() {
        resetFeedAndResizeState()
        backend = nil
    }

    /// 在尚未取得后端时（如认证解析失败）直接置失败态。
    func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    /// 关闭当前后端并复位。切换服务器前调用。
    func close() async {
        if let backend { await backend.close() }
        resetFeedAndResizeState()
        backend = nil
        connectionState = .idle
    }

    /// Bump the feed generation and tear down every in-flight feed/flush/resize
    /// task and buffer, so stale output from a previous binding is rejected by
    /// both the ingress task and the flush loop. The generation bump must come
    /// first for that rejection to be reliable.
    private func resetFeedAndResizeState() {
        feedGeneration &+= 1
        feedTask?.cancel()
        feedTask = nil
        outputFlushTask?.cancel()
        outputFlushTask = nil
        outputBuffer.clear()
        pendingResize = nil
        resizeFlushTask?.cancel()
        resizeFlushTask = nil
        lastForwardedResize = nil
        exitObserverTask?.cancel()
        exitObserverTask = nil
    }

    private func startFeedLoop() {
        guard let backend else { return }
        let myGen = feedGeneration
        let buffer = outputBuffer

        // Iterate on a detached task so it isn't gated by MainActor work
        // (SwiftUI rendering, other panes' feed loops). Chunks are staged in a
        // bounded buffer and a MainActor flusher feeds SwiftTerm on a frame-like
        // cadence instead of hopping to MainActor for every output batch.
        feedTask = Task.detached(priority: .userInitiated) {
            let stream = backend.outputStream
            for await chunk in stream {
                if Task.isCancelled { break }
                buffer.append(chunk, generation: myGen)
            }
        }
    }

    private func startOutputFlushLoop() {
        outputFlushTask?.cancel()
        let myGen = feedGeneration
        let buffer = outputBuffer
        outputFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.feedGeneration == myGen else { return }

                let didFeed = self.flushPendingOutput(generation: myGen)
                if didFeed {
                    // 活跃路径：让短时间内陆续到达的字节合批一次性 feed。
                    try? await Task.sleep(for: .milliseconds(self.outputFlushActiveMs))
                } else {
                    // 空闲路径：挂起到下一次 append（或 clear 唤醒，让被取消的
                    // generation 通过下一轮顶部的 guard 退出）。这条路径取代了
                    // 旧的 100ms 轮询 —— 那 100ms 是 echo 字符在终端中可见前
                    // 的最坏延迟，是"输入不跟手"的根因。
                    await buffer.waitForData()
                }
            }
        }
    }

    private func flushPendingOutput(generation: Int) -> Bool {
        guard feedGeneration == generation else { return false }
        let chunk = outputBuffer.drain(maxBytes: maxBytesPerOutputFlush, generation: generation)
        guard !chunk.isEmpty else { return false }

        let bytes = ArraySlice([UInt8](chunk))
        terminalView.feed(byteArray: bytes)
        return true
    }

}
