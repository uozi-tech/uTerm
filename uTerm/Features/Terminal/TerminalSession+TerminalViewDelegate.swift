import SwiftUI
import SwiftTerm
import AppKit

// MARK: - TerminalViewDelegate

extension TerminalSession {
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        // 交互式 SSH 终端：将键盘 / 粘贴输入字节转发给后端。
        //
        // Ordering note: each keystroke spawns its own detached `Task` to call
        // `backend?.write`. Two Tasks created in rapid succession could in
        // principle hop onto the backend actor out of creation order. Correct
        // keystroke ordering therefore relies on `SSHConnection`'s internal
        // ordered write FIFO, which serializes writes regardless of the order
        // these Tasks reach the actor. Do not assume Task creation order here.
        let bytes = Data(data)
        Task { [weak self] in
            await self?.backend?.write(bytes)
        }
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        let cols = UInt16(clamping: newCols)
        let rows = UInt16(clamping: newRows)
        latestReportedResize = (cols, rows)
        // 终端刚按新尺寸重排过：镜像端改发一份新尺寸下的快照，不去追字节级的时序。
        mirrorTap.invalidateAll()

        // Fast path: SwiftTerm sometimes fires sizeChanged for the same value
        // during a layout pass; no SIGWINCH needed.
        if let last = lastForwardedResize, last.cols == cols && last.rows == rows {
            pendingResize = nil
            resizeFlushTask?.cancel()
            resizeFlushTask = nil
            return
        }

        // 尺寸已由 TerminalContainerView 等停稳才提交，这里不再按时间防抖：缓冲区已经重排，
        // 程序越早知道越好。只合并同一轮主线程里的连续变化（`pinRemoteGrid` 会连设几次尺寸）。
        pendingResize = (cols, rows)
        resizeFlushTask?.cancel()
        resizeFlushTask = Task { [weak self] in
            if Task.isCancelled { return }
            await self?.flushPendingResize()
        }
    }

    func forwardResizeImmediately(_ size: (cols: UInt16, rows: UInt16)) {
        pendingResize = nil
        resizeFlushTask?.cancel()
        resizeFlushTask = nil
        lastForwardedResize = size
        Task { [weak self] in
            await self?.backend?.resize(cols: size.cols, rows: size.rows)
        }
    }

    private func flushPendingResize() async {
        guard let pending = pendingResize else { return }
        pendingResize = nil
        resizeFlushTask = nil
        lastForwardedResize = pending
        await backend?.resize(cols: pending.cols, rows: pending.rows)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        guard let string = String(data: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
