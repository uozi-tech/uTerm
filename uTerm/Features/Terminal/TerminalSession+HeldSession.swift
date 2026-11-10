import Foundation

/// 持有 PTY 的后端（`HeldTerminalBackend`）接回画面、存检查点。
///
/// 画面只有 App 这边的终端引擎懂，holder 只存字节。所以 App 定期把影子终端的状态拍成一张二进制快照
///（检查点）连同它对应的字节位置交给 holder。接回时：把检查点还原进影子终端，再喂那个位置之后的字节，影子就回到了
/// 最新画面；画面（surface）等标签第一次露出时再建，建好后由输出泵把影子的状态回放进去（M7）。
///
/// 检查点的快照只认同一个引擎版本存的（`TerminalCheckpointBlob`）：版本变了就丢弃，holder 里的 shell 不受影响，只是回滚
/// 历史从 holder 还留着的那段字节开始。和快照存在一起的程序状态不认版本，照用。
///
/// 回放的字节全是历史。里面的终端查询、命令跟踪标记、状态上报、通知，当时要么已经处理过，要么过时了，
/// 所以按历史喂给影子（`ShadowTerminal.feed(_:asHistory:)`）：不应答、不写剪贴板、不发通知、不认标记，否则历史查询的
/// 回答会打进 shell 的输入。「历史」跟着字节走而不是一个会话级的开关：回放途中（每片之间让出主线程）用户的按键照常发出。
/// 只有程序状态例外：它跟检查点存在一起，回放的那段字节里的状态变化也照收——一直在 working 的程序跨重启不会再报一次。
extension TerminalSession {
    private static let replayChunkBytes = 256 * 1024

    /// 接回完成返回 true；返回 false 说明回放途中这条会话已经被换掉，调用方别再往下走。
    func restoreHeldScreen(from backend: any HeldTerminalBackend, generation: Int) async -> Bool {
        HeldTerminalSessions.add(self)
        guard let replay = await backend.takeReplay() else { return true }
        guard feedGeneration == generation else { return false }

        let checkpoint = replay.checkpoint
        var restored = false
        if let snapshot = TerminalCheckpointBlob.decode(checkpoint.blob) {
            restored = (try? shadow.restore(snapshot: snapshot)) != nil
        }
        // 程序状态跟检查点存在一起：一直在 working 的程序接回后不会再报一次，标签上的圆点只能从这里来。
        // 快照用不了（别的引擎版本存的）也照用：状态对应的是检查点那个字节位置，和快照格式无关。
        if let status = TerminalCheckpointBlob.decodeProgramStatus(checkpoint.blob).flatMap(ProgramStatusJournal.decode) {
            events.restore(status)
        }
        // 检查点没法用（空的、别的引擎版本存的）：之后的字节仍然是按当时的尺寸产生的，先回到那个尺寸。
        if !restored, checkpoint.cols > 0, checkpoint.rows > 0 {
            shadow.resize(cols: checkpoint.cols, rows: checkpoint.rows)
        }
        if checkpoint.hasGap {
            let notice = String(localized: "重启期间输出过多，较早内容已丢弃")
            shadow.feed(Data("\r\n\u{1b}[2m[\(notice)]\u{1b}[0m\r\n".utf8), asHistory: true)
        }
        guard await feedReplay(replay.output, generation: generation) else { return false }

        // 画面已经有网格的话（重连同一个窗格）回到它的尺寸；没建过的等它第一次报网格时影子自然跟上。
        if let grid = ghostty.grid {
            shadow.resize(cols: UInt16(clamping: grid.cols), rows: UInt16(clamping: grid.rows))
        }
        // 影子是绕过输出泵改的：画面、镜像都要重新对齐。
        outputPump.markSurfaceStale()
        mirrorTap.invalidateAll()
        // 检查点里的状态 + 回放那段字节里的状态变化：接回的那一刻标签上就是对的，不等程序下一次上报。
        publishProgramStatus()
        // 都没有的话，状态是丢了还是本来就没有程序，光看检查点分不出来（检查点是别的引擎版本存的、存的时候还不带状态……）。
        if replay.isReattach, !programStatusTracker.hasRecords { askForegroundAfterReattach(backend, generation: generation) }

        heldCheckpoints = TerminalHeldCheckpoints(link: backend.holderLink, pump: outputPump, baseOffset: replay.endOffset,
                                                  programStatus: { [statusJournal] in statusJournal.encoded })

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

    /// 接回后马上问一次前台是谁：不是 shell 就当它是重启前一直在跑的 Agent（它只在状态变化时才报，不会为接回再报一次），
    /// 直到它真的报了状态或者回到提示符（`ProgramStatusTracker.presumedProgram`）；⌘V 贴图据此同步判断。不挡着接回：
    /// SSH 的 holder 要开一条 exec 通道去问，最长等到超时。问的途中程序已经开口了就不用这个结论。
    private func askForegroundAfterReattach(_ backend: any HeldTerminalBackend, generation: Int) {
        Task { [weak self] in
            let activity = await backend.foregroundActivity()
            guard let self, self.feedGeneration == generation, !self.programStatusTracker.hasRecords,
                  case .running(let name) = activity else { return }
            self.events.presumeRunningProgram(name ?? "")
            self.publishProgramStatus()
        }
    }

    private func feedReplay(_ bytes: [UInt8], generation: Int) async -> Bool {
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.replayChunkBytes, bytes.count)
            shadow.feed(Data(bytes[start..<end]), asHistory: true)
            start = end
            // 最多 16 MiB，一口气喂会占住主线程。
            await Task.yield()
            guard feedGeneration == generation else { return false }
        }
        return true
    }

    /// 此刻存检查点的话会存下的那份数据（快照 + 程序状态）。测试用它模拟「重启前最后一次检查点」。
    func makeHeldCheckpointBlob() throws -> [UInt8] {
        try outputPump.performWhileFeedingPaused {
            TerminalCheckpointBlob.encode(snapshot: try shadow.snapshot(), programStatus: statusJournal.encoded)
        }
    }

    /// 退出流程里最后存一次。
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

/// 检查点的数据：版本头 + 程序状态 + 影子终端的二进制快照。版本头认不出来或者和现在的引擎不是同一个版本，就当没有检查点。
nonisolated enum TerminalCheckpointBlob {
    private static let magic = Array("uTermCP\u{2}".utf8)

    /// `programStatus`：`ProgramStatusJournal.encoded`（引擎的快照里不带程序状态，那是宿主记的）。
    static func encode(snapshot: Data, programStatus: Data? = nil, engine: String = TerminalEngineVersion.current) -> [UInt8] {
        let version = Array(engine.utf8.prefix(255))
        let status = programStatus ?? Data()
        let length = UInt32(status.count)
        let lengthBytes = [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        return magic + [UInt8(version.count)] + version + lengthBytes + status + snapshot
    }

    /// 快照部分；不是这个引擎版本存的返回 nil。
    static func decode(_ blob: [UInt8], engine: String = TerminalEngineVersion.current) -> Data? {
        decodeContents(blob, engine: engine)?.snapshot
    }

    static func decodeContents(_ blob: [UInt8], engine: String = TerminalEngineVersion.current)
        -> (snapshot: Data, programStatus: Data?)? {
        guard let parts = split(blob), parts.engine == Array(engine.utf8.prefix(255)) else { return nil }
        return (parts.snapshot, parts.programStatus)
    }

    /// 程序状态那一段，不核引擎版本：状态是宿主记的（`ProgramStatusJournal` 的 JSON），和快照格式无关，换了引擎、
    /// 快照用不了时照样对应着检查点那个字节位置。
    static func decodeProgramStatus(_ blob: [UInt8]) -> Data? {
        split(blob)?.programStatus
    }

    private static func split(_ blob: [UInt8]) -> (engine: [UInt8], programStatus: Data?, snapshot: Data)? {
        guard blob.count > magic.count, Array(blob.prefix(magic.count)) == magic else { return nil }
        let versionLength = Int(blob[magic.count])
        var cursor = magic.count + 1
        guard blob.count >= cursor + versionLength + 4 else { return nil }
        let engine = Array(blob[cursor..<(cursor + versionLength)])
        cursor += versionLength
        let statusLength = blob[cursor..<(cursor + 4)].reduce(0) { $0 << 8 | Int($1) }
        cursor += 4
        guard blob.count > cursor + statusLength else { return nil }
        let status = statusLength > 0 ? Data(blob[cursor..<(cursor + statusLength)]) : nil
        return (engine, status, Data(blob[(cursor + statusLength)...]))
    }
}

/// 什么时候存检查点：累计一段输出存一次；尺寸变了很快存一次（之后的字节是按新尺寸产生的）；退出时存一次。
/// 不按时间存：之后的字节都在 holder 里（16 MiB），接回时重放就行。
///
/// 「一段输出」至少 4 MiB；快照比这大（回滚设得很长）时按上一张快照的大小来，最多 12 MiB——快照带着整段回滚，
/// 这样每输出 1 字节最多摊 1 字节检查点，又不会超出 holder 留着的那 16 MiB。
///
/// 线程：`noteFed` 在输出泵喂字节的那条线程上调（泵的锁在手上），其余在主线程上；拍快照和算字节位置都借泵的锁做，
/// 所以检查点和它声称的位置严格对应。
nonisolated final class TerminalHeldCheckpoints: @unchecked Sendable {
    private static let resizeDelay = 0.3
    private static let minPendingBytes = 4 * 1024 * 1024
    private static let maxPendingBytes = 12 * 1024 * 1024

    private let link: HolderLink
    private let pump: TerminalOutputPump
    private let baseOffset: UInt64
    private let programStatus: @Sendable () -> Data?
    private let lock = NSLock()
    private var fedBytes: UInt64 = 0
    private var bytesSinceCapture = 0
    private var lastBlobBytes = 0
    private var isDirty = false
    private var scheduleToken = 0

    /// `programStatus`：此刻的程序状态（`ProgramStatusJournal.encoded`），和快照存在一起。
    init(link: HolderLink, pump: TerminalOutputPump, baseOffset: UInt64,
         programStatus: @escaping @Sendable () -> Data? = { nil }) {
        self.link = link
        self.pump = pump
        self.baseOffset = baseOffset
        self.programStatus = programStatus
    }

    /// 影子终端又吃进去 `count` 字节（泵的 tap）。
    func noteFed(_ count: Int) {
        lock.lock()
        fedBytes += UInt64(count)
        bytesSinceCapture += count
        isDirty = true
        let due = bytesSinceCapture >= min(Self.maxPendingBytes, max(Self.minPendingBytes, lastBlobBytes))
        lock.unlock()
        if due { captureNow() }
    }

    /// 画面发生了不经过字节流的变化（尺寸变了）：过一会儿存一次。
    func noteScreenChanged() {
        lock.lock()
        isDirty = true
        scheduleToken &+= 1
        let token = scheduleToken
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDelay) { [weak self] in
            guard let self, self.lock.withLock({ self.scheduleToken == token }) else { return }
            self.captureNow()
        }
    }

    func cancel() {
        lock.withLock { scheduleToken &+= 1 }
    }

    func captureNow() {
        pump.performWhileFeedingPaused {
            lock.lock()
            guard isDirty else {
                lock.unlock()
                return
            }
            let offset = baseOffset + fedBytes
            lock.unlock()
            guard let snapshot = try? pump.shadow.snapshot() else { return }
            let size = pump.shadow.size
            let blob = TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: programStatus())
            lock.lock()
            isDirty = false
            bytesSinceCapture = 0
            lastBlobBytes = blob.count
            lock.unlock()
            link.checkpoint(offset: offset, cols: UInt16(clamping: size.cols), rows: UInt16(clamping: size.rows), blob: blob)
        }
    }
}
