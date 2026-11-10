import Foundation
import SwiftTerm

/// 持有 PTY 的后端（`HeldTerminalBackend`）接回画面、存检查点。
///
/// 画面只有 App 这边的终端解析器懂，holder 只存字节。所以 App 定期把终端状态序列化成一块不透明的数据
///（检查点）连同它对应的字节位置交给 holder。接回时：喂检查点，再喂那个位置之后的字节，就回到了最新画面。
///
/// 回放的字节全是历史。里面的终端查询、OSC 52、命令跟踪标记，当时要么已经处理过，要么过时了，
/// 所以回放期间屏蔽应答和副作用（`isReplayingHeldOutput`），否则历史查询的回答会打进 shell 的输入。
extension TerminalSession {
    private static let replayChunkBytes = 256 * 1024

    /// 接回完成返回 true；返回 false 说明回放途中这条会话已经被换掉，调用方别再往下走。
    func restoreHeldScreen(from backend: any HeldTerminalBackend, generation: Int) async -> Bool {
        HeldTerminalSessions.add(self)
        guard let replay = await backend.takeReplay() else { return true }
        guard feedGeneration == generation else { return false }

        let terminal = terminalView.getTerminal()
        let checkpoint = replay.checkpoint
        // 检查点和之后的字节都是按当时的尺寸产生的，要先回到那个尺寸。窗口尺寸等视图布局时再改回来。
        if !checkpoint.blob.isEmpty, checkpoint.cols > 0, checkpoint.rows > 0 {
            terminal.resize(cols: Int(checkpoint.cols), rows: Int(checkpoint.rows))
            shadow.resize(cols: checkpoint.cols, rows: checkpoint.rows)
        }

        isReplayingHeldOutput = true
        shadow.setEventsSuppressed(true)
        defer {
            isReplayingHeldOutput = false
            shadow.setEventsSuppressed(false)
        }
        guard await feedReplay(checkpoint.blob, generation: generation) else { return false }
        if checkpoint.hasGap {
            let notice = String(localized: "重启期间输出过多，较早内容已丢弃")
            guard await feedReplay(Array("\r\n\u{1b}[2m[\(notice)]\u{1b}[0m\r\n".utf8), generation: generation) else { return false }
        }
        guard await feedReplay(replay.output, generation: generation) else { return false }

        heldCheckpoints = TerminalHeldCheckpoints(
            link: backend.holderLink, terminal: terminal, baseOffset: replay.endOffset,
            buffer: outputBuffer, generation: generation)

        if replay.isReattach {
            // 尺寸没变时 TIOCSWINSZ 不发信号，TUI 不知道要重画。等视图布局一轮（尺寸变了的话已经发过了）再补一个。
            let link = backend.holderLink
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.feedGeneration == generation else { return }
                link.send(HolderFrame(.redraw))
            }
        }
        return true
    }

    private func feedReplay(_ bytes: [UInt8], generation: Int) async -> Bool {
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.replayChunkBytes, bytes.count)
            terminalView.feed(byteArray: bytes[start..<end])
            shadow.feed(Data(bytes[start..<end]))
            start = end
            // 最多 16 MiB，一口气喂会卡住界面。
            await Task.yield()
            guard feedGeneration == generation else { return false }
        }
        return true
    }

    /// 退出流程里最后存一次。不在解析边界就算了：holder 里还有上一个检查点和之后的全部字节。
    func saveHeldCheckpointNow() {
        heldCheckpoints?.captureNow()
    }

    /// 窗格被关掉时调（代替 `dispose()` + `close()`）：平时结束会话；退出 App 途中只断开，会话留着下次接回。
    func closeForDisposal() {
        // `dispose()` 会清掉 backend，之后 `close()` 就关不到它了，要先留一份。
        let backend = backend
        // 退出流程里异步任务不一定来得及跑，要同步把话说完。
        if TerminalQuitPolicy.shared.isQuitting, let held = backend as? any HeldTerminalBackend {
            finishHeldForQuit(endingSession: TerminalQuitPolicy.shared.endsSessionsOnQuit)
            dispose()
            Task { await held.detach() }
        } else {
            dispose()
            Task { await backend?.close() }
        }
    }

    /// 退出流程的最后一步（`willTerminate`）：之后进程就没了，不能再指望异步任务。
    func finishHeldForQuit(endingSession: Bool) {
        guard let held = backend as? any HeldTerminalBackend else { return }
        saveHeldCheckpointNow()
        if endingSession { held.holderLink.send(HolderFrame(.terminate)) }
        held.holderLink.flushAndClose(timeout: 0.5)
    }
}

/// 所有连着 holder 的终端会话，退出询问和退出收尾要枚举它们。弱引用：会话的生命周期归窗口。
@MainActor
enum HeldTerminalSessions {
    private struct Entry {
        weak var session: TerminalSession?
    }

    private static var entries: [Entry] = []

    static func add(_ session: TerminalSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
        entries.append(Entry(session: session))
    }

    static var all: [TerminalSession] { entries.compactMap(\.session) }
}

/// 什么时候存检查点：累计 4 MiB 输出存一次；尺寸变了很快存一次（之后的字节是按新尺寸产生的）；退出时存一次。
/// 不按时间存：之后的字节都在 holder 里（16 MiB），接回时重放就行，最多重放 4 MiB。
/// 而序列化要读解析器，只能在主线程上做，3000 行回滚最少 30ms，会让正在进行的滚动明显掉帧。
/// Claude Code 思考时每秒只输出约 1 KB，按时间存等于全程隔几秒卡一下。
@MainActor
final class TerminalHeldCheckpoints {
    private static let resizeDelay = Duration.milliseconds(300)
    private static let retryDelay = Duration.milliseconds(200)
    private static let maxPendingBytes = 4 * 1024 * 1024
    /// 回滚设置可以调得很大，检查点不跟着涨。
    private static let maxScrollbackLines = 20_000

    private let link: HolderLink
    private let terminal: Terminal
    private let baseOffset: UInt64
    private let buffer: TerminalOutputBuffer
    private let generation: Int
    private var fedBytes: UInt64 = 0
    private var bytesSinceCapture = 0
    private var isDirty = false
    private var scheduled: Task<Void, Never>?

    init(link: HolderLink, terminal: Terminal, baseOffset: UInt64, buffer: TerminalOutputBuffer, generation: Int) {
        self.link = link
        self.terminal = terminal
        self.baseOffset = baseOffset
        self.buffer = buffer
        self.generation = generation
    }

    /// 已解析的字节 + 被缓冲丢掉的字节 = 输出流的一个前缀（缓冲只从头丢），下一次接回就从这里续。
    private var offset: UInt64 {
        baseOffset + fedBytes + buffer.droppedBytes(generation: generation)
    }

    func noteFed(_ count: Int) {
        fedBytes += UInt64(count)
        bytesSinceCapture += count
        markDirty()
        if bytesSinceCapture >= Self.maxPendingBytes {
            captureNow()
        }
    }

    func noteScreenChanged() {
        markDirty()
        scheduled?.cancel()
        schedule(after: Self.resizeDelay)
    }

    func cancel() {
        scheduled?.cancel()
        scheduled = nil
    }

    private func markDirty() {
        isDirty = true
    }

    private func schedule(after delay: Duration) {
        scheduled = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            if self.terminal.isAtSnapshotBoundary {
                self.captureNow()
            } else {
                self.schedule(after: Self.retryDelay)
            }
        }
    }

    func captureNow() {
        guard isDirty, terminal.isAtSnapshotBoundary else { return }
        isDirty = false
        bytesSinceCapture = 0
        let blob = terminal.snapshotSequence(scrollbackLimit: min(terminal.options.scrollback, Self.maxScrollbackLines))
        link.checkpoint(offset: offset, cols: UInt16(clamping: terminal.cols), rows: UInt16(clamping: terminal.rows), blob: blob)
    }
}
