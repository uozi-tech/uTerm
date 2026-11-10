import Foundation

/// 接在输出泵上，替画面那一侧收拾两件事（两端共用，平台那边只给两个主线程上的动作）：
///
/// 1. **擦屏后清选区。** 泵认出清屏、擦回滚、复位、进出备用屏、擦掉一段（`TerminalErase`），surface 解析到那里之后告诉这里；
///    这里合并成一次跳回主线程（只擦了一段的攒 50 ms），让视图清选区（擦掉一段的只在选区里只剩空白时清）。Ghostty 引擎清屏不清选区，高亮会留在
///    擦空的格子上、拷贝拿到空白。
/// 2. **整屏回放后找回视口。** 标签切走（App 进后台、surface 被放掉）之前平台那边记一个视口位置（`remember`）；
///    surface 追上影子时，补的是尾巴就什么都不用做（视口、选区都还在），是整屏回放的话（复位把视口带回了底部）按记下的
///    位置在影子里找回原处、滚过去。找行在自己的后台队列上做，不占主线程、也不占 surface 的输出队列。
nonisolated final class TerminalSurfaceKeeper: @unchecked Sendable {
    private let lock = NSLock()
    private var mark: TerminalViewportMark?
    private var pendingErase: TerminalErase?
    private var eraseHopScheduled = false
    private let shadow: ShadowTerminal
    private let clearSelection: @MainActor @Sendable (TerminalErase) -> Void
    private let scrollToRow: @MainActor @Sendable (Int) -> Void

    private static let searchQueue = DispatchQueue(label: "com.uozi.uTerm.viewport-search", qos: .userInitiated)
    private var restoredRow: Int?
    /// 测试用：最近一次整屏回放后算出来的目标行（nil = 留在底部或没记位置）。
    var lastRestoredRow: Int? { lock.withLock { restoredRow } }

    /// `clearSelection`：清选区（参数是哪一档擦屏）。`scrollToRow`：把视口首行滚到整屏第几行。都在主线程上调。
    init(pump: TerminalOutputPump, shadow: ShadowTerminal,
         clearSelection: @escaping @MainActor @Sendable (TerminalErase) -> Void,
         scrollToRow: @escaping @MainActor @Sendable (Int) -> Void) {
        self.shadow = shadow
        self.clearSelection = clearSelection
        self.scrollToRow = scrollToRow
        pump.onSurfaceErase = { [weak self] erase in self?.surfaceErased(erase) }
        pump.onSurfaceCaughtUp = { [weak self] kind in self?.surfaceCaughtUp(kind) }
    }

    // MARK: 视口

    /// 记下视口位置（surface 将要停喂 / 被放掉之前调）。已经记着一个还没用掉的就不换：那是更早、更准的一次——
    /// 回放还没解析完时 surface 的视口已经被复位带到了底部，这时再记会把原处冲掉。
    func remember(_ mark: TerminalViewportMark?) {
        lock.withLock {
            if self.mark == nil { self.mark = mark }
        }
    }

    /// 丢掉记着的位置（surface 回到屏上、却不用追：视口一直在原处）。
    func forget() {
        lock.withLock { mark = nil }
    }

    /// 记着一个视口位置没有（测试用）。
    var hasMark: Bool { lock.withLock { mark != nil } }

    private func surfaceCaughtUp(_ kind: TerminalOutputPump.CatchUp) {
        let mark: TerminalViewportMark? = lock.withLock {
            defer { self.mark = nil }
            return self.mark
        }
        guard kind == .replay, let mark else { return }
        // 找行不占 surface 的输出队列（后面排着的输出要接着交给 surface）；持一次影子的锁找完。
        Self.searchQueue.async { [weak self] in
            guard let self else { return }
            let row = self.shadow.readScreen { size, rowText in
                mark.targetRow(totalRows: size.totalRows, rows: size.rows, columns: size.cols, rowText: rowText)
            }
            self.lock.withLock { self.restoredRow = row }
            guard let row else { return }
            let scroll = self.scrollToRow
            DispatchQueue.main.async { MainActor.assumeIsolated { scroll(row) } }
        }
    }

    // MARK: 擦屏

    private func surfaceErased(_ erase: TerminalErase) {
        let schedule: Bool = lock.withLock {
            pendingErase = max(pendingErase ?? erase, erase)
            defer { eraseHopScheduled = true }
            return !eraseHopScheduled
        }
        guard schedule else { return }
        // 只擦了一段的要读一遍选区里的文字（选区可能很大）；全屏程序重画时每一帧都有 EL：攒一小会儿再看一次。
        let delay: TimeInterval = erase == .screen ? 0 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let erase: TerminalErase? = self.lock.withLock {
                    defer {
                        self.pendingErase = nil
                        self.eraseHopScheduled = false
                    }
                    return self.pendingErase
                }
                if let erase { self.clearSelection(erase) }
            }
        }
    }
}
