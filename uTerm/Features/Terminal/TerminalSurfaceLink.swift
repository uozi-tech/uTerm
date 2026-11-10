import Foundation
import GhosttyTerminal
import os
#if canImport(AppKit)
import AppKit
/// Ghostty 的平台视图（两端的 uTerm 本地补丁接口相同，见 `UTERM-PATCHES.md`）。
typealias TerminalHostedView = AppTerminalView
#else
import UIKit
typealias TerminalHostedView = UITerminalView
#endif

/// 一条终端的「影子 + surface」接线，两端共用这一份（Mac 的 `TerminalSession` / `GhosttyTerminalBridge`、iOS 的
/// `GhosttyTerminalBridge` 各持一个）。平台那边只剩视图、按键、尺寸怎么发给 PTY、在不在屏上这些事。
///
/// 管这几样：
/// - **建立**：影子终端、Ghostty 的 host-managed IO（`InMemoryTerminalSession`）、输出泵。IO 的 resize 回调里影子当场跟上
///   surface 的终端报来的网格（M4 的前提：不按视图尺寸算、不绕主线程），新 surface 出生时的默认网格那一次不认
///   （`TerminalSurfaceGridGate`）；远控主控端的影子跟着对端的快照走（`followsRemoteGrid`）。
/// - **回主线程**：surface 的写出（击键、应答）与网格报告、影子的应答 / 剪贴板 / 事件都从任意线程回到主线程，一律走主队列
///   （`TerminalMainHop`：FIFO，击键和应答的先后不乱）。
/// - **surface 就绪**：surface 建好之后，等它的终端报来的网格和视图算出来的对上（兜底 0.25 s）才让泵开始喂它；拆掉时
///   关闸、记为落后（下一个 surface 是空的，要整屏回放）。
/// - **整屏回放之后**：把影子的标题再交一次（影子被快照整个换掉时不会逐条发事件）；擦屏后清选区、回放后找回视口（`keeper`）。
@MainActor
final class TerminalSurfaceLink {
    let shadow: ShadowTerminal
    /// Ghostty 的 host-managed IO：输出从这里进 surface，键盘输入与应答从它的回调出来。
    let io: InMemoryTerminalSession
    /// 输出泵：后端输出 → 影子 → tap → surface。
    let pump: TerminalOutputPump
    /// 新 surface 的网格报告认不认（IO 线程上读）。
    let gridGate: TerminalSurfaceGridGate
    /// 影子终端事件的处理（程序状态、查询应答、历史、远控镜像）。平台接它的出口。
    let events = TerminalEventRouter()
    /// 远控主控端（后端 `mirrorsRemoteGrid`）：影子的网格跟着对端的快照走，surface 报来的网格只发给对端、不改影子。
    /// IO 线程的 resize 回调读它。
    let followsRemoteGrid: OSAllocatedUnfairLock<Bool>
    /// 擦屏后清选区、整屏回放后找回视口。
    private(set) var keeper: TerminalSurfaceKeeper!
    private weak var view: TerminalHostedView?

    // MARK: 平台出口（都在主线程上调）

    /// surface 发出的字节（击键、粘贴、它答的查询）。
    var onSurfaceInput: (Data) -> Void = { _ in }
    /// 影子替 surface 答的查询（surface 不吃字节的时候）。
    var onShadowReply: (Data) -> Void = { _ in }
    /// 程序写剪贴板（OSC 52；影子喂历史时不来）。
    var onClipboardWrite: (String) -> Void = { _ in }
    /// surface 的终端报来了网格（IO 线程上已经认下、影子已经跟上），或者兜底认下了拦过的那一次。平台在这里把尺寸发给 PTY，
    /// 并调 `gridReported(cols:rows:)`。
    var onGridReported: (InMemoryTerminalViewport) -> Void = { _ in }
    var onSurfaceAttached: () -> Void = {}
    var onSurfaceDetached: () -> Void = {}
    /// 平台允许 surface 吃字节吗（Mac：视图在窗口里；iOS：App 在前台）。条件变了平台调 `syncSurfaceFeeding()`。
    var platformAllowsFeeding: () -> Bool = { true }

    // MARK: 状态

    /// surface 建着（视图进过窗口、没被放掉）。
    private(set) var hasSurface = false
    /// surface 建好了，并且它的终端报出了和视图一致的网格（或兜底超时了）：这时才往里灌回放、接实时字节。
    private(set) var isSurfaceReady = false
    private var expectedGrid: (cols: Int, rows: Int)?
    private var reportedGridSinceAttach: (cols: Int, rows: Int)?
    private var surfaceSizeTimeout: Task<Void, Never>?
    private var shadowColorsAreDark: Bool?

    init(cols: UInt16, rows: UInt16, options: ShadowTerminal.Options) {
        let shadow = ShadowTerminal(cols: cols, rows: rows, options: options)
        let relay = Relay()
        let gridGate = TerminalSurfaceGridGate()
        self.gridGate = gridGate
        let follows = OSAllocatedUnfairLock(initialState: false)
        self.shadow = shadow
        followsRemoteGrid = follows
        io = InMemoryTerminalSession(
            write: { relay.surfaceWrote($0) },
            resize: { viewport in
                // 新 surface 先按出生时的默认网格报一次，再报真实的：那一次不认（见 `TerminalSurfaceGridGate`）。
                guard gridGate.admits(viewport) else { return }
                // 影子只认这个回调报来的网格（surface 的终端自己的尺寸），当场跟上；格子像素给尺寸查询用。
                if !follows.withLock({ $0 }) {
                    shadow.resize(cols: viewport.columns, rows: viewport.rows,
                                  cellWidth: viewport.cellWidthPixels, cellHeight: viewport.cellHeightPixels)
                }
                relay.surfaceResized(viewport)
            },
            // 只有行列数要发给远端（SIGWINCH）；像素级变化（拖分隔条时绝大多数）不用。
            suppressesPixelOnlyResizes: true)
        pump = TerminalOutputPump(shadow: shadow, surface: io)
        relay.link = self
        shadow.setReplyHandler { data in
            TerminalMainHop.run { relay.link?.onShadowReply(data) }
        }
        shadow.setClipboardWriteHandler { text in
            TerminalMainHop.run { relay.link?.onClipboardWrite(text) }
        }
        events.install(on: shadow)
        // 影子被整个换掉（远控快照、接回）后回放进 surface：标题不会逐条发事件，回放之后对一次。
        pump.onReplayed = {
            TerminalMainHop.run {
                guard let link = relay.link else { return }
                link.events.onEvent(.titleChanged(link.shadow.title))
            }
        }
        keeper = TerminalSurfaceKeeper(
            pump: pump, shadow: shadow,
            clearSelection: { [weak self] erase in _ = self?.view?.uTermClearSelection(onlyIfBlank: erase == .inPlace) },
            scrollToRow: { [weak self] row in _ = self?.view?.scrollToRow(UInt(row)) })
    }

    deinit {
        surfaceSizeTimeout?.cancel()
    }

    /// IO 回调（任意线程）回到主线程上的 link。link 建好之前就要交给 IO，所以中间隔一个弱引用的盒子。
    private nonisolated final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private weak var target: TerminalSurfaceLink?

        var link: TerminalSurfaceLink? {
            get { lock.withLock { target } }
            set { lock.withLock { target = newValue } }
        }

        func surfaceWrote(_ data: Data) {
            TerminalMainHop.run { self.link?.onSurfaceInput(data) }
        }

        func surfaceResized(_ viewport: InMemoryTerminalViewport) {
            TerminalMainHop.run { self.link?.onGridReported(viewport) }
        }
    }

    /// 接上画面的视图：surface 的生灭与视图算出来的网格由它报来。
    func attach(_ view: TerminalHostedView) {
        self.view = view
        view.uTermOnSurfaceAttached = { [weak self] in self?.surfaceAttached() }
        view.uTermOnSurfaceDetached = { [weak self] in self?.surfaceDetached() }
        view.uTermSetGridExpectedHandler { [weak self] cols, rows in self?.gridExpected(cols: cols, rows: rows) }
    }

    /// 接一条新后端之前（两端共用的准备）：重连先复位光标形状（`CSI 0 q`，影子没内容时不送）；远控主控端的影子跟着对端
    /// 的快照走、画面等网格对齐再跟。调用方先 `pump.reset()`（换绑定的代次）。
    func prepare(for backend: any TerminalBackend) {
        let mirrors = backend.mirrorsRemoteGrid
        followsRemoteGrid.withLock { $0 = mirrors }
        pump.resetCursorShapeForNewConnection()
        pump.followsSnapshotGrid = mirrors
    }

    // MARK: surface 的生与灭

    /// surface 建好了。它的终端此刻还是出生时的默认网格（Mac 上按 800×600 px 算出约 53×21，iOS 上 30×10 这种），真实尺寸
    /// 要等 IO 线程处理完第一条 resize 才生效；在那之前灌进去的回放会按错的网格解析（备用屏的内容尤其会错位，而且网格
    /// 和以前一样时程序收不到 SIGWINCH、不会重画）。所以等它的终端报来的网格和视图算出来的对上了再开闸：视图那边主线程上
    /// 当场就知道该是多少（`gridExpected`），终端那边由 resize 回调报来。兜底等 0.25 s。
    private func surfaceAttached() {
        hasSurface = true
        isSurfaceReady = false
        expectedGrid = nil
        reportedGridSinceAttach = nil
        gridGate.surfaceAttached()
        surfaceSizeTimeout?.cancel()
        surfaceSizeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            // 兜底：没等到对得上的那一次。把拦下的最后一次报告认了，开闸。
            if let held = self.gridGate.settle() { self.adopt(held) }
            self.surfaceBecameReady()
        }
        onSurfaceAttached()
    }

    /// surface 没了（放掉了、视图被销毁、换了 controller 重建）：输出只进影子，下一个 surface 建好时再回放——
    /// 哪怕这期间一个字节都没来：新 surface 是空的。
    private func surfaceDetached() {
        hasSurface = false
        isSurfaceReady = false
        surfaceSizeTimeout?.cancel()
        surfaceSizeTimeout = nil
        gridGate.surfaceDetached()
        onSurfaceDetached()
        syncSurfaceFeeding()
        pump.markSurfaceStale()
    }

    /// 视图按自己的尺寸算出来的网格（surface 刚建好、以及之后每次尺寸变化，主线程上同步报来）。
    private func gridExpected(cols: Int, rows: Int) {
        expectedGrid = (cols, rows)
        // 终端的报告先到、当时还对不上被拦下了：现在对上了就认它。
        if let held = gridGate.expect(cols: cols, rows: rows) { adopt(held) }
        openGateIfGridSettled()
    }

    /// 认下一次被拦过的网格报告（和 resize 回调里放行的那条路做同样的事）。
    private func adopt(_ viewport: InMemoryTerminalViewport) {
        if !followsRemoteGrid.withLock({ $0 }) {
            shadow.resize(cols: viewport.columns, rows: viewport.rows,
                          cellWidth: viewport.cellWidthPixels, cellHeight: viewport.cellHeightPixels)
        }
        onGridReported(viewport)
    }

    /// 平台在 `onGridReported` 里调：远控主控端停着画面等网格对齐的话，现在可能对上了；surface 刚建好的话看闸能不能开。
    func gridReported(cols: Int, rows: Int) {
        pump.surfaceGridDidChange()
        if hasSurface, !isSurfaceReady {
            reportedGridSinceAttach = (cols, rows)
            openGateIfGridSettled()
        }
    }

    private func openGateIfGridSettled() {
        guard !isSurfaceReady, hasSurface, let expectedGrid, let reported = reportedGridSinceAttach,
              expectedGrid == reported else { return }
        surfaceBecameReady()
    }

    private func surfaceBecameReady() {
        surfaceSizeTimeout?.cancel()
        surfaceSizeTimeout = nil
        guard !isSurfaceReady, hasSurface else { return }
        isSurfaceReady = true
        // 影子此刻已经在 surface 的终端报来的网格上（resize 回调里当场改的、或兜底认下的那一次）：回放流按它生成。
        syncSurfaceFeeding()
    }

    /// 画面能吃字节的条件：平台允许（`platformAllowsFeeding`），且 surface 建好、网格到位。任何一条不成立就只喂影子；
    /// 重新成立时输出泵让 surface 追上影子再接实时字节。重复调用无害。
    func syncSurfaceFeeding() {
        pump.setSurfaceFeeding(platformAllowsFeeding() && isSurfaceReady)
    }

    // MARK: 视口

    /// 停喂 / 放掉 surface 之前，按 surface 此刻的滚动条和视口文字记下视口位置（在底部就不记）：之后要是只能整屏回放，
    /// 回来时找回这里。
    func rememberViewport() {
        guard hasSurface, let view, !view.uTermIsSurfaceReleased, let bar = view.uTermScrollbar,
              let columns = io.surfaceGrid?.columns else { return }
        keeper.remember(TerminalViewportMark.capture(offset: Int(bar.offset), rows: Int(bar.len), total: Int(bar.total),
                                                     columns: Int(columns), viewportText: io.readViewportText()))
    }

    /// 回到屏上（或回前台）：期间没来过输出，surface 一直停在原处、不用追，记着的视口作废。
    func forgetViewportUnlessCatchingUp() {
        if !pump.surfaceNeedsCatchUp { keeper.forget() }
    }

    // MARK: 配色

    /// surface 不吃字节时由影子答颜色查询（OSC 10 / 11 / 12、`CSI ? 996 n`），要用当前配色。值没变就不动。
    func syncShadowColors(dark: Bool) {
        guard shadowColorsAreDark != dark else { return }
        shadowColorsAreDark = dark
        let scheme = TerminalColorScheme.resolve(dark: dark)
        shadow.setDefaultColors(foreground: TerminalRGB(scheme.foregroundColor).components,
                                background: TerminalRGB(scheme.backgroundColor).components,
                                cursor: TerminalRGB(scheme.cursorColor).components, dark: dark)
    }
}
